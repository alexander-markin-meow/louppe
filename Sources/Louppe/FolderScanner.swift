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

        let volumeIsCaseSensitive = (try? root.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? false

        // Pair building is cheap; collect every (primary, paired) pair first
        // so the expensive per-file metadata reads can run in parallel below.
        let pairs = pairFiles(
            files,
            pairingMode: pairingMode,
            caseSensitiveNames: volumeIsCaseSensitive
        )
        if isCancelled() { throw CancellationError() }

        var result = try makeItems(
            for: pairs,
            factsByURL: factsByURL,
            rootPath: root.standardizedFileURL.path,
            isCancelled: isCancelled
        )

        result.sort { a, b in
            switch (a.captureDate, b.captureDate) {
            case let (da?, db?) where da != db: return da < db
            case (nil, .some): return false
            case (.some, nil): return true
            default: return a.id.localizedStandardCompare(b.id) == .orderedAscending
            }
        }
        return result
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
            let videos = urls.filter { isVideoExtension($0.pathExtension) }
            for video in videos { pairs.append((video, nil)) }

            let images = urls.filter { !isVideoExtension($0.pathExtension) }
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

    private static func stableURLOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path < rhs.standardizedFileURL.path
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
                let facts = factsByURL[primary]
                let isVideo = isVideoExtension(primary.pathExtension)
                let info = isVideo ? MetadataExtractor.ScanInfo() : MetadataExtractor.scanInfo(for: primary)
                let videoInfo = isVideo ? VideoMetadataExtractor.scanInfo(for: primary) : nil
                let captureDate = info.captureDate ?? facts?.creationDate
                items.append(PhotoItem(
                    id: relativePath(of: primary, under: rootPath),
                    primaryURL: primary,
                    pairedURL: paired,
                    captureDate: captureDate,
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
                    primaryModificationDate: facts?.modificationDate,
                    fileSize: facts?.size ?? 0,
                    pairedFileSize: paired.flatMap { factsByURL[$0]?.size } ?? 0
                ))
            }
            chunkResults.store(items, at: chunkIndex)
        }
        if isCancelled() { throw CancellationError() }
        return chunkResults.flattened()
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

    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
