import Foundation
import UniformTypeIdentifiers

/// Recursively discovers photos in a folder and turns them into `PhotoItem`s:
/// pairs RAW+JPEG shots, reads capture dates, and sorts chronologically.
/// Pure file-system work with no UI state — safe to run on any thread.
enum FolderScanner {
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

    /// `progress` is called periodically with the running file count. The
    /// cancellation hook lets a superseded scan stop before it walks or opens
    /// the rest of a large card; it is polled from concurrent metadata
    /// workers too, so it must be safe to call from any thread.
    static func scan(
        _ root: URL,
        pairingMode: RawJPEGPairingMode = .together,
        isCancelled: @Sendable () -> Bool = { false },
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
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
            ])
            guard values?.isRegularFile == true else { continue }
            files.append(url)
            factsByURL[url] = FileFacts(
                size: Int64(values?.fileSize ?? 0),
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate
            )
            if files.count % 25 == 0 { progress(files.count) }
        }

        let volumeIsCaseSensitive = caseSensitiveNames(at: root)

        // Pair building is cheap; collect every (primary, paired) pair first
        // so the expensive per-file metadata reads can run in parallel below.
        let pairs = pairFiles(
            files,
            pairingMode: pairingMode,
            caseSensitiveNames: volumeIsCaseSensitive
        )
        if isCancelled() { throw CancellationError() }

        let result = try makeItems(
            for: pairs,
            factsByURL: factsByURL,
            rootPath: root.standardizedFileURL.path,
            isCancelled: isCancelled
        )
        return sortItems(result)
    }

    /// Deterministic RAW+JPEG pairing independent of filesystem enumerator and
    /// Dictionary iteration order. Internal so the ordering contract can be
    /// regression tested without scanning real media.
    static func pairFiles(
        _ files: [URL],
        pairingMode: RawJPEGPairingMode,
        caseSensitiveNames: Bool
    ) -> [(primary: URL, paired: URL?)] {
        var groups: [String: [URL]] = [:]
        for url in files.sorted(by: stableURLOrder) {
            let basePath = url.deletingPathExtension().standardizedFileURL.path
            let key = caseSensitiveNames
                ? basePath
                : basePath.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
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

            if pairingMode == .together, let raw = raws.first, let jpeg = jpegs.first {
                pairs.append((raw, jpeg))
                // Rare leftovers (e.g., two RAWs or JPEGs with the same base
                // name) become separate items without duplicating either side
                // of the one real pair.
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
                fileByPath[file.url.standardizedFileURL.path] = file
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
                ($0.url.standardizedFileURL.path, $0)
            }
        )
        let pairs = pairFiles(
            files.map(\.url),
            pairingMode: pairingMode,
            caseSensitiveNames: caseSensitiveNames(at: root)
        )
        var projected: [PhotoItem] = []
        projected.reserveCapacity(pairs.count)
        var itemIDByFileID: [String: String] = [:]
        for pair in pairs {
            guard let primary = filesByPath[pair.primary.standardizedFileURL.path] else {
                continue
            }
            let paired = pair.paired.flatMap {
                filesByPath[$0.standardizedFileURL.path]
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
        lhs.standardizedFileURL.path < rhs.standardizedFileURL.path
    }

    private static func caseSensitiveNames(at root: URL) -> Bool {
        (try? root.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? false
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
        rootPath: String,
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
                    rootPath: rootPath
                )
                let pairedFile = paired.map {
                    lightweightFile(
                        at: $0,
                        facts: factsByURL[$0],
                        rootPath: rootPath
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
        rootPath: String
    ) -> PhotoFile {
        let isVideo = isVideoExtension(url.pathExtension)
        let info = isVideo
            ? MetadataExtractor.ScanInfo()
            : MetadataExtractor.scanInfo(for: url)
        let videoInfo = isVideo ? VideoMetadataExtractor.scanInfo(for: url) : nil
        return PhotoFile(
            id: relativePath(of: url, under: rootPath),
            url: url,
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
            fileSize: facts?.size ?? 0
        )
    }

    /// A hidden JPEG needs only facts already returned by folder enumeration.
    /// Its EXIF remains unopened until the user asks to review the files
    /// separately, keeping the common paired scan as fast as before.
    private static func lightweightFile(
        at url: URL,
        facts: FileFacts?,
        rootPath: String
    ) -> PhotoFile {
        PhotoFile(
            id: relativePath(of: url, under: rootPath),
            url: url,
            captureDate: facts?.creationDate,
            cameraModel: nil,
            lensModel: nil,
            modificationDate: facts?.modificationDate,
            fileSize: facts?.size ?? 0,
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
        let rating = file.ratingSnapshot
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
            metadataIsLoaded: true,
            rating: rating.rating,
            ratedAt: rating.ratedAt
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

    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
