import Foundation

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

    /// Visual files we recognise but can't preview — RAW formats ImageIO
    /// doesn't decode, and video. They show up in the session as a grey
    /// "file isn't supported" placeholder instead of being silently dropped.
    static let unsupportedVisualExtensions: Set<String> = [
        // RAW formats ImageIO can't decode
        "x3f", "kdc", "mef", "gpr",
        // Video
        "mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg", "wmv", "flv",
        "webm", "3gp", "mts", "m2ts", "hevc", "insv",
    ]

    /// Everything we surface in a session — previewable or placeholder.
    static let recognizedExtensions: Set<String> = supportedExtensions.union(unsupportedVisualExtensions)

    /// SD cards nest photos under e.g. DCIM/100NIKON/, so scan recursively —
    /// but not endlessly, in case of symlink loops or pathological trees.
    static let maxScanDepth = 5

    private struct FileFacts {
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
        isCancelled: () -> Bool = { false },
        progress: (Int) -> Void
    ) throws -> [PhotoItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
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
            if enumerator.level > maxScanDepth {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard recognizedExtensions.contains(ext) else { continue }
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

        // Group RAW+JPEG pairs: same folder, same base filename.
        var groups: [String: [URL]] = [:]
        for url in files {
            if isCancelled() { throw CancellationError() }
            let key = url.deletingPathExtension().path.lowercased()
            groups[key, default: []].append(url)
        }

        // Pair building is cheap; collect every (primary, paired) pair first
        // so the expensive per-file metadata reads can run in parallel below.
        var pairs: [(primary: URL, paired: URL?)] = []
        pairs.reserveCapacity(files.count)
        for (_, urls) in groups {
            if isCancelled() { throw CancellationError() }
            let raws = urls.filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            let nonRaws = urls.filter { !rawExtensions.contains($0.pathExtension.lowercased()) }

            if let raw = raws.first, let jpeg = nonRaws.first {
                pairs.append((raw, jpeg))
                // Rare leftovers (e.g., two RAWs with the same base name) become separate items.
                for extra in raws.dropFirst() { pairs.append((extra, nil)) }
                for extra in nonRaws.dropFirst() { pairs.append((extra, nil)) }
            } else {
                for url in urls { pairs.append((url, nil)) }
            }
        }

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
        isCancelled: () -> Bool
    ) throws -> [PhotoItem] {
        guard !pairs.isEmpty else { return [] }
        let chunkSize = max(1, (pairs.count + maxMetadataConcurrency - 1) / maxMetadataConcurrency)
        let chunkStarts = Array(stride(from: 0, to: pairs.count, by: chunkSize))
        var chunkResults = [[PhotoItem]](repeating: [], count: chunkStarts.count)
        chunkResults.withUnsafeMutableBufferPointer { slots in
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
                    let info = MetadataExtractor.scanInfo(for: primary)
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
                        primaryModificationDate: facts?.modificationDate,
                        fileSize: facts?.size ?? 0,
                        pairedFileSize: paired.flatMap { factsByURL[$0]?.size } ?? 0
                    ))
                }
                slots[chunkIndex] = items
            }
        }
        if isCancelled() { throw CancellationError() }
        return chunkResults.flatMap { $0 }
    }

    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
