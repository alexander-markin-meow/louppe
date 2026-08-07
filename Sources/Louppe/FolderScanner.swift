import Foundation
import UniformTypeIdentifiers

/// Recursively discovers photos in a folder and turns them into `PhotoItem`s:
/// pairs RAW+JPEG shots, reads capture dates, and sorts chronologically.
/// Pure file-system work with no UI state — safe to run on any thread.
enum FolderScanner {
    enum ScanError: LocalizedError {
        case filesChangedDuringScan

        var errorDescription: String? {
            "A photo or video changed while Louppe was scanning. Nothing was saved; scan the folder again."
        }
    }
    /// Camera RAW formats macOS's ImageIO can decode (verified against
    /// CGImageSourceCopyTypeIdentifiers on this machine).
    static let rawExtensions: Set<String> = [
        "nef", "nrw",               // Nikon
        "raf",                      // Fujifilm
        "dng",                      // Adobe / many cameras
        "cr2", "cr3", "crw",        // Canon
        "arw", "sr2", "srf",        // Sony
        "orf",                      // Olympus
        "rw2", "raw",               // Panasonic / Leica
        "pef",                      // Pentax
        "srw",                      // Samsung
        "3fr", "fff",               // Hasselblad
        "dcr",                      // Kodak
        "mos",                      // Leaf
        "iiq",                      // Phase One
        "mrw",                      // Konica Minolta
        "erf",                      // Epson
        "rwl",                      // Leica
    ]

    /// Types we can actually decode and preview: RAWs above, plus the
    /// still-image formats ImageIO handles.
    static let supportedExtensions: Set<String> = rawExtensions.union([
        "jpg", "jpeg", "tif", "tiff",
        "png", "gif", "bmp", "heic", "heif", "hif",
        "webp", "avif", "jxl", "jp2", "psd", "tga", "ico",
    ])

    /// Movie extensions commonly found on cameras, phones, drones, and web
    /// downloads. `isVideoExtension` also asks Uniform Type Identifiers, so
    /// formats added by macOS media extensions are discovered automatically.
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg", "wmv", "flv",
        "webm", "3gp", "3g2", "mts", "m2ts", "m2v", "hevc", "insv",
    ]

    /// Visual files we recognise but can't preview — RAW formats ImageIO
    /// doesn't decode. They show up in the session as a grey
    /// "file isn't supported" placeholder instead of being silently dropped.
    static let unsupportedVisualExtensions: Set<String> = [
        // RAW formats ImageIO can't decode
        "x3f", "kdc", "mef", "gpr",
    ]

    /// Everything we surface in a session — previewable or placeholder.
    static let recognizedExtensions: Set<String> = supportedExtensions
        .union(unsupportedVisualExtensions)
        .union(videoExtensions)

    static func isVideoExtension(_ ext: String) -> Bool {
        let normalized = ext.lowercased()
        if videoExtensions.contains(normalized) { return true }
        // Known still-image formats never need a Uniform Type Identifier
        // lookup. Pairing and metadata construction ask this repeatedly, so
        // keep their common photo path to two in-memory Set lookups.
        if supportedExtensions.contains(normalized)
            || unsupportedVisualExtensions.contains(normalized) {
            return false
        }
        return UTType(filenameExtension: normalized)?.conforms(to: .movie) == true
    }

    static func isRecognizedExtension(_ ext: String) -> Bool {
        recognizedExtensions.contains(ext.lowercased()) || isVideoExtension(ext)
    }

    private struct FileFacts: Sendable {
        let size: Int64
        let creationDate: Date?
        let modificationDate: Date?
        let identity: FileOperationJournal.FileIdentity
    }

    /// Thread-safe cancellation signal for a scan. `Task.isCancelled` only
    /// reflects cancellation on the task's own thread; the scan's parallel
    /// metadata workers run on GCD threads, so callers bridge task
    /// cancellation through this flag (see `SessionStore.openFolder`).
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }
    }

    struct PairingProjection: Sendable {
        let items: [PhotoItem]
        /// Every physical file id resolves to the displayed item that owns it.
        /// This keeps the current photo and selection stable when a JPEG item
        /// is folded into its RAW partner.
        let itemIDByFileID: [String: String]
        /// Number of hidden partner files whose metadata had to be opened.
        /// Exposed for deterministic regression checks and progress decisions.
        let enrichedFileCount: Int
    }

    /// Filename-stem equality used only for RAW+JPEG pairing.
    ///
    /// A case-insensitive volume may equate `SHOT` and `shot`, but it does not
    /// equate genuinely different accented names such as `cafe` and `café`.
    /// Unknown volume capabilities deliberately use case-sensitive matching:
    /// failing to form a real pair is safer than grouping unrelated originals.
    struct PairingFilenamePolicy: Equatable, Sendable {
        let caseSensitiveNames: Bool

        fileprivate struct Key: Hashable, Comparable {
            /// Conservative stem equality across the whole opened folder:
            /// exact bytes on case-sensitive or unknown volumes, ASCII case
            /// folding only when the volume explicitly reports
            /// case-insensitive names. A group is paired only when it contains
            /// exactly one RAW and one JPEG, so repeated camera filenames in
            /// different subfolders remain safely independent.
            let stemBytes: Data

            static func < (lhs: Key, rhs: Key) -> Bool {
                return lhs.stemBytes.lexicographicallyPrecedes(rhs.stemBytes)
            }
        }

        init(caseSensitiveNames: Bool) {
            self.caseSensitiveNames = caseSensitiveNames
        }

        init(volumeSupportsCaseSensitiveNames: Bool?) {
            caseSensitiveNames = volumeSupportsCaseSensitiveNames ?? true
        }

        fileprivate func key(for url: URL) -> Key {
            let path = Self.fileSystemBytes(for: url)
            let separator = path.lastIndex(of: 47)
            let filenameStart = separator.map { $0 + 1 } ?? path.startIndex
            let extensionSeparator = path[filenameStart...]
                .lastIndex(of: 46)
            let stemEnd = extensionSeparator ?? path.endIndex
            let stem = Array(path[filenameStart..<stemEnd])
            return Key(
                stemBytes: caseSensitiveNames
                    ? Data(stem)
                    : Data(stem.map(Self.foldASCIICase))
            )
        }

        private static func fileSystemBytes(for url: URL) -> [UInt8] {
            url.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else {
                    return Array(url.path(percentEncoded: true).utf8)
                }
                var count = 0
                while pointer[count] != 0 { count += 1 }
                return UnsafeBufferPointer(start: pointer, count: count)
                    .map(UInt8.init(bitPattern:))
            }
        }

        private static func foldASCIICase(_ byte: UInt8) -> UInt8 {
            (65...90).contains(byte) ? byte + 32 : byte
        }
    }

    /// `progress` is called periodically with the running file count. The
    /// cancellation hook lets a superseded scan stop before it walks or opens
    /// the rest of a large card; it is polled from concurrent metadata
    /// workers too, so it must be safe to call from any thread.
    static func scan(
        _ root: URL,
        pairingMode: RawJPEGPairingMode = .separate,
        isCancelled: @Sendable () -> Bool = { false },
        beforeFinalIdentityValidation: () throws -> Void = {},
        progress: (Int) -> Void
    ) throws -> [PhotoItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .volumeURLKey,
                .volumeUUIDStringKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw NSError(domain: "Louppe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read that folder."])
        }
        if isCancelled() { throw CancellationError() }

        var files: [URL] = []
        var factsByURL: [URL: FileFacts] = [:]
        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            let navigationValues = try? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            // Scan legitimate deeply nested archives without a silent depth
            // cutoff, but never traverse a symbolic-link directory loop.
            if navigationValues?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard isRecognizedExtension(ext) else { continue }
            // These keys were prefetched by the enumerator above. Keep their
            // values now instead of issuing separate attributes/resource calls
            // for every primary photo later in the scan.
            guard let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                    .volumeURLKey,
                    .volumeUUIDStringKey,
                  ]) else {
                throw ScanError.filesChangedDuringScan
            }
            guard values.isRegularFile == true else { continue }
            guard let identity = try? FileOperationJournal.captureIdentity(
                    at: url,
                    volumeRoot: values.volume,
                    volumeUUIDString: values.volumeUUIDString
                  ) else {
                throw ScanError.filesChangedDuringScan
            }
            files.append(url)
            factsByURL[url] = FileFacts(
                size: Int64(values.fileSize ?? 0),
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate,
                identity: identity
            )
            if files.count % 25 == 0 { progress(files.count) }
        }

        let filenamePolicy = pairingFilenamePolicy(at: root)

        // Pair building is cheap; collect every (primary, paired) pair first
        // so the expensive per-file metadata reads can run in parallel below.
        let pairs = pairFiles(
            files,
            pairingMode: pairingMode,
            filenamePolicy: filenamePolicy
        )
        if isCancelled() { throw CancellationError() }

        let result = try makeItems(
            for: pairs,
            factsByURL: factsByURL,
            root: root,
            isCancelled: isCancelled
        )
        try beforeFinalIdentityValidation()
        try validateScannedIdentities(result)
        return sortItems(result)
    }

    /// Metadata decoding can take seconds for a large card. Re-stat every
    /// pathname after that work so an atomic replacement cannot combine old
    /// identity/rating state with newly substituted bytes.
    static func validateScannedIdentities(_ items: [PhotoItem]) throws {
        for file in items.flatMap(\.individualFiles) {
            guard let expected = file.scannedIdentity,
                  let current = try? FileOperationJournal.captureIdentity(
                    at: file.url
                  ),
                  FileOperationJournal.identitiesMatch(
                    expected: expected,
                    actual: current,
                    includeStatusChange: true
                  ) else {
                throw ScanError.filesChangedDuringScan
            }
        }
    }

    /// Deterministic RAW+JPEG pairing independent of filesystem enumerator and
    /// Dictionary iteration order. Internal so the ordering contract can be
    /// regression tested without scanning real media.
    static func pairFiles(
        _ files: [URL],
        pairingMode: RawJPEGPairingMode,
        caseSensitiveNames: Bool
    ) -> [(primary: URL, paired: URL?)] {
        pairFiles(
            files,
            pairingMode: pairingMode,
            filenamePolicy: PairingFilenamePolicy(
                caseSensitiveNames: caseSensitiveNames
            )
        )
    }

    static func pairFiles(
        _ files: [URL],
        pairingMode: RawJPEGPairingMode,
        filenamePolicy: PairingFilenamePolicy
    ) -> [(primary: URL, paired: URL?)] {
        var groups: [PairingFilenamePolicy.Key: [URL]] = [:]
        for url in files.sorted(by: stableURLOrder) {
            let key = filenamePolicy.key(for: url)
            groups[key, default: []].append(url)
        }

        var pairs: [(primary: URL, paired: URL?)] = []
        pairs.reserveCapacity(files.count)
        for key in groups.keys.sorted() {
            guard let grouped = groups[key] else { continue }
            let urls = grouped.sorted(by: stableURLOrder)
            // Videos are always independent media, even when a camera gives a
            // RAW and sidecar movie the same base name. Only RAW + JPEG is a
            // pair; pairing a RAW with MOV/PNG/TIFF would make the latter
            // disappear from the review session.
            var videos: [URL] = []
            var images: [URL] = []
            for url in urls {
                if isVideoExtension(url.pathExtension) {
                    videos.append(url)
                } else {
                    images.append(url)
                }
            }
            for video in videos { pairs.append((video, nil)) }
            let raws = images.filter {
                rawExtensions.contains($0.pathExtension.lowercased())
            }
            let jpegs = images.filter {
                ["jpg", "jpeg"].contains($0.pathExtension.lowercased())
            }

            // A shared stem is not enough evidence when more than one file
            // could fill either side. Never let sort order arbitrarily decide
            // which original owns a JPEG: ambiguous groups stay independent.
            if pairingMode == .together,
               raws.count == 1,
               jpegs.count == 1,
               let raw = raws.first,
               let jpeg = jpegs.first {
                pairs.append((raw, jpeg))
                // Other image formats sharing the stem remain independent.
                for extra in images where extra != raw && extra != jpeg {
                    pairs.append((extra, nil))
                }
            } else {
                for url in images { pairs.append((url, nil)) }
            }
        }
        return pairs
    }

    /// Reprojects the already-discovered physical files without walking the
    /// source folder again. Separating a paired session opens metadata only
    /// for lightweight JPEG partners; every later toggle reuses those records.
    static func projectPairingMode(
        _ pairingMode: RawJPEGPairingMode,
        from items: [PhotoItem],
        root: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> PairingProjection {
        var fileByPath: [String: PhotoFile] = [:]
        for item in items {
            for file in item.individualFiles {
                fileByPath[fileSystemIdentityPath(for: file.url)] = file
            }
        }
        var files = fileByPath.values.sorted { stableURLOrder($0.url, $1.url) }
        let missingMetadataCount: Int
        if pairingMode == .separate {
            missingMetadataCount = files.count { !$0.metadataIsLoaded }
            files = try prepareMissingMetadata(in: files, isCancelled: isCancelled)
        } else {
            missingMetadataCount = 0
        }
        if isCancelled() { throw CancellationError() }

        let filesByPath = Dictionary(
            uniqueKeysWithValues: files.map {
                (fileSystemIdentityPath(for: $0.url), $0)
            }
        )
        let pairs = pairFiles(
            files.map(\.url),
            pairingMode: pairingMode,
            filenamePolicy: pairingFilenamePolicy(at: root)
        )
        var projected: [PhotoItem] = []
        projected.reserveCapacity(pairs.count)
        var itemIDByFileID: [String: String] = [:]
        for pair in pairs {
            guard let primary = filesByPath[
                fileSystemIdentityPath(for: pair.primary)
            ] else {
                continue
            }
            let paired = pair.paired.flatMap {
                filesByPath[fileSystemIdentityPath(for: $0)]
            }
            let item = PhotoItem(primaryFile: primary, pairedFile: paired)
            projected.append(item)
            for file in item.individualFiles {
                itemIDByFileID[file.id] = item.id
            }
        }
        return PairingProjection(
            items: sortItems(projected),
            itemIDByFileID: itemIDByFileID,
            enrichedFileCount: missingMetadataCount
        )
    }

    private static func stableURLOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        fileSystemIdentityPath(for: lhs)
            < fileSystemIdentityPath(for: rhs)
    }

    private static func pairingFilenamePolicy(
        at root: URL
    ) -> PairingFilenamePolicy {
        let capability = try? root.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames
        return PairingFilenamePolicy(
            volumeSupportsCaseSensitiveNames: capability
        )
    }

    /// `PreparedSessionIndex` reuses this physical order for `PhotoSort()`.
    /// Keep the scanner and the UI comparator literally shared so opening a
    /// folder never needs to repeat the same large localized-name sort.
    static func sortItems(_ items: [PhotoItem]) -> [PhotoItem] {
        let defaultSort = PhotoSort()
        return items.sorted(by: defaultSort.areInOrder)
    }

    /// How many EXIF readers run at once during a scan. Header parsing mixes
    /// file I/O with CPU work, so a handful of workers saturates it without
    /// competing with the rest of the system.
    private static let maxMetadataConcurrency = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// Reading EXIF opens every file and dominates scan time, so the pair
    /// list is split into contiguous chunks processed concurrently. Each
    /// chunk fills its own result slot (a single writer per slot) and the
    /// slots are concatenated in order, making the outcome identical to a
    /// serial pass; the caller's chronological sort settles the final order
    /// either way.
    private static func makeItems(
        for pairs: [(primary: URL, paired: URL?)],
        factsByURL: [URL: FileFacts],
        root: URL,
        isCancelled: @Sendable () -> Bool
    ) throws -> [PhotoItem] {
        guard !pairs.isEmpty else { return [] }
        let chunkSize = max(1, (pairs.count + maxMetadataConcurrency - 1) / maxMetadataConcurrency)
        let chunkStarts = Array(stride(from: 0, to: pairs.count, by: chunkSize))
        let chunkResults = ChunkResults(count: chunkStarts.count)
        DispatchQueue.concurrentPerform(iterations: chunkStarts.count) { chunkIndex in
            let start = chunkStarts[chunkIndex]
            let end = min(start + chunkSize, pairs.count)
            var items: [PhotoItem] = []
            items.reserveCapacity(end - start)
            for (primary, paired) in pairs[start..<end] {
                // A cancelled scan's partial chunk is discarded by the
                // throw below, so stopping mid-chunk is safe.
                if isCancelled() { return }
                let primaryFile = scannedFile(
                    at: primary,
                    facts: factsByURL[primary],
                    root: root
                )
                let pairedFile = paired.map {
                    lightweightFile(
                        at: $0,
                        facts: factsByURL[$0],
                        root: root
                    )
                }
                items.append(
                    PhotoItem(primaryFile: primaryFile, pairedFile: pairedFile)
                )
            }
            chunkResults.store(items, at: chunkIndex)
        }
        if isCancelled() { throw CancellationError() }
        return chunkResults.flattened()
    }

    private static func scannedFile(
        at url: URL,
        facts: FileFacts?,
        root: URL
    ) -> PhotoFile {
        let isVideo = isVideoExtension(url.pathExtension)
        let info = isVideo
            ? MetadataExtractor.ScanInfo()
            : MetadataExtractor.scanInfo(for: url)
        let videoInfo = isVideo ? VideoMetadataExtractor.scanInfo(for: url) : nil
        return PhotoFile(
            id: relativeFileIdentity(of: url, under: root),
            url: url,
            displayRelativePath: relativeDisplayPath(of: url, under: root),
            captureDate: info.captureDate ?? facts?.creationDate,
            cameraModel: info.cameraModel,
            lensModel: info.lensModel,
            aperture: info.aperture,
            shutterSpeed: info.shutterSpeed,
            iso: info.iso,
            mediaKind: isVideo ? .video : .photo,
            duration: videoInfo?.duration,
            videoDimensions: videoInfo?.dimensions,
            videoCodec: videoInfo?.codec,
            videoFrameRate: videoInfo?.frameRate,
            videoIsPlayable: videoInfo?.isPlayable ?? false,
            modificationDate: facts?.modificationDate,
            fileSize: facts?.size ?? 0,
            scannedIdentity: facts?.identity
        )
    }

    /// A hidden JPEG needs only facts already returned by folder enumeration.
    /// Its EXIF remains unopened until the user asks to review the files
    /// separately, keeping the common paired scan as fast as before.
    private static func lightweightFile(
        at url: URL,
        facts: FileFacts?,
        root: URL
    ) -> PhotoFile {
        PhotoFile(
            id: relativeFileIdentity(of: url, under: root),
            url: url,
            displayRelativePath: relativeDisplayPath(of: url, under: root),
            captureDate: facts?.creationDate,
            cameraModel: nil,
            lensModel: nil,
            modificationDate: facts?.modificationDate,
            fileSize: facts?.size ?? 0,
            scannedIdentity: facts?.identity,
            metadataIsLoaded: false
        )
    }

    private static func prepareMissingMetadata(
        in files: [PhotoFile],
        isCancelled: @Sendable () -> Bool
    ) throws -> [PhotoFile] {
        guard files.contains(where: { !$0.metadataIsLoaded }) else {
            return files
        }
        let chunkSize = max(
            1,
            (files.count + maxMetadataConcurrency - 1) / maxMetadataConcurrency
        )
        let chunkStarts = Array(stride(from: 0, to: files.count, by: chunkSize))
        let results = FileChunkResults(count: chunkStarts.count)
        DispatchQueue.concurrentPerform(iterations: chunkStarts.count) { chunkIndex in
            let start = chunkStarts[chunkIndex]
            let end = min(start + chunkSize, files.count)
            var prepared: [PhotoFile] = []
            prepared.reserveCapacity(end - start)
            for file in files[start..<end] {
                if isCancelled() { return }
                prepared.append(
                    file.metadataIsLoaded ? file : enrichMetadata(for: file)
                )
            }
            results.store(prepared, at: chunkIndex)
        }
        if isCancelled() { throw CancellationError() }
        return results.flattened()
    }

    private static func enrichMetadata(for file: PhotoFile) -> PhotoFile {
        let metadata = file.metadataSnapshot
        let isVideo = isVideoExtension(file.url.pathExtension)
        let info = isVideo
            ? MetadataExtractor.ScanInfo()
            : MetadataExtractor.scanInfo(for: file.url)
        let videoInfo = isVideo
            ? VideoMetadataExtractor.scanInfo(for: file.url)
            : nil
        return PhotoFile(
            id: file.id,
            url: file.url,
            displayRelativePath: file.legacyPersistenceID,
            captureDate: info.captureDate ?? file.captureDate,
            cameraModel: info.cameraModel,
            lensModel: info.lensModel,
            aperture: info.aperture,
            shutterSpeed: info.shutterSpeed,
            iso: info.iso,
            mediaKind: isVideo ? .video : .photo,
            duration: videoInfo?.duration,
            videoDimensions: videoInfo?.dimensions,
            videoCodec: videoInfo?.codec,
            videoFrameRate: videoInfo?.frameRate,
            videoIsPlayable: videoInfo?.isPlayable ?? false,
            modificationDate: file.modificationDate,
            fileSize: file.fileSize,
            scannedIdentity: file.scannedIdentity,
            metadataIsLoaded: true,
            rating: metadata.rating,
            ratedAt: metadata.ratedAt,
            starRating: metadata.starRating,
            starsChangedAt: metadata.starsChangedAt,
            colorLabel: metadata.colorLabel,
            colorChangedAt: metadata.colorChangedAt
        )
    }

    /// `DispatchQueue.concurrentPerform` requires a Sendable capture. The
    /// previous unsafe mutable-buffer capture had one writer per slot but was
    /// rejected by Swift 6's concurrency model. This box keeps the same
    /// bounded parallelism and deterministic chunk order while synchronizing
    /// only the tiny per-chunk assignment.
    private final class ChunkResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[PhotoItem]]

        init(count: Int) {
            values = [[PhotoItem]](repeating: [], count: count)
        }

        func store(_ items: [PhotoItem], at index: Int) {
            lock.lock()
            values[index] = items
            lock.unlock()
        }

        func flattened() -> [PhotoItem] {
            lock.lock()
            defer { lock.unlock() }
            return values.flatMap { $0 }
        }
    }

    private final class FileChunkResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[PhotoFile]]

        init(count: Int) {
            values = [[PhotoFile]](repeating: [], count: count)
        }

        func store(_ files: [PhotoFile], at index: Int) {
            lock.lock()
            values[index] = files
            lock.unlock()
        }

        func flattened() -> [PhotoFile] {
            lock.lock()
            defer { lock.unlock() }
            return values.flatMap { $0 }
        }
    }

    /// Lossless, persistence-friendly path identity. Foundation `String`
    /// equality treats canonically equivalent Unicode spellings as equal,
    /// while a normalization-sensitive filesystem can store both. Percent-
    /// encoded URL paths remain ASCII and retain their exact filesystem bytes.
    static func fileSystemIdentityPath(for url: URL) -> String {
        url.path(percentEncoded: true)
    }

    static func relativeFileIdentity(of url: URL, under root: URL) -> String {
        let path = fileSystemIdentityPath(for: url)
        let rootPath = fileSystemIdentityPath(for: root)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootedPrefix = rootPath.isEmpty ? "/" : "/\(rootPath)/"
        if path.hasPrefix(rootedPrefix) {
            return String(path.dropFirst(rootedPrefix.count))
        }
        let absoluteRoot = rootPath.isEmpty ? "/" : "/\(rootPath)"
        if path.hasPrefix(absoluteRoot + "/") {
            return String(path.dropFirst(absoluteRoot.count + 1))
        }
        return path.split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
            ?? path
    }

    private static func relativeDisplayPath(
        of url: URL,
        under root: URL
    ) -> String {
        let path = url.path
        let rootPath = root.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
