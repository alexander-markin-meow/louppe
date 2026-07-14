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
    }

    /// `progress` is called periodically with the running file count. The
    /// cancellation hook lets a superseded scan stop before it walks or opens
    /// the rest of a large card.
    static func scan(
        _ root: URL,
        isCancelled: () -> Bool = { false },
        progress: (Int) -> Void
    ) throws -> [PhotoItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
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
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey])
            guard values?.isRegularFile == true else { continue }
            files.append(url)
            factsByURL[url] = FileFacts(
                size: Int64(values?.fileSize ?? 0),
                creationDate: values?.creationDate
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

        var result: [PhotoItem] = []
        let rootPath = root.standardizedFileURL.path
        for (_, urls) in groups {
            if isCancelled() { throw CancellationError() }
            let raws = urls.filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            let nonRaws = urls.filter { !rawExtensions.contains($0.pathExtension.lowercased()) }

            var pairs: [(primary: URL, paired: URL?)] = []
            if let raw = raws.first, let jpeg = nonRaws.first {
                pairs.append((raw, jpeg))
                // Rare leftovers (e.g., two RAWs with the same base name) become separate items.
                for extra in raws.dropFirst() { pairs.append((extra, nil)) }
                for extra in nonRaws.dropFirst() { pairs.append((extra, nil)) }
            } else {
                for url in urls { pairs.append((url, nil)) }
            }

            for (primary, paired) in pairs {
                if isCancelled() { throw CancellationError() }
                let facts = factsByURL[primary]
                let info = MetadataExtractor.scanInfo(for: primary)
                let captureDate = info.captureDate ?? facts?.creationDate
                result.append(PhotoItem(
                    id: relativePath(of: primary, under: rootPath),
                    primaryURL: primary,
                    pairedURL: paired,
                    captureDate: captureDate,
                    cameraModel: info.cameraModel,
                    lensModel: info.lensModel,
                    fileSize: facts?.size ?? 0
                ))
            }
        }

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

    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
