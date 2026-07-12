import Foundation

/// Recursively discovers photos in a folder and turns them into `PhotoItem`s:
/// pairs RAW+JPEG shots, reads capture dates, and sorts chronologically.
/// Pure file-system work with no UI state — safe to run on any thread.
enum FolderScanner {
    static let supportedExtensions: Set<String> = ["nef", "raf", "jpg", "jpeg", "tif", "tiff"]
    static let rawExtensions: Set<String> = ["nef", "raf"]

    /// SD cards nest photos under e.g. DCIM/100NIKON/, so scan recursively —
    /// but not endlessly, in case of symlink loops or pathological trees.
    static let maxScanDepth = 5

    /// `progress` is called periodically with the running file count.
    static func scan(_ root: URL, progress: (Int) -> Void) throws -> [PhotoItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw NSError(domain: "Louppe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read that folder."])
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > maxScanDepth {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append(url)
            if files.count % 25 == 0 { progress(files.count) }
        }

        // Group RAW+JPEG pairs: same folder, same base filename.
        var groups: [String: [URL]] = [:]
        for url in files {
            let key = url.deletingPathExtension().path.lowercased()
            groups[key, default: []].append(url)
        }

        var result: [PhotoItem] = []
        let rootPath = root.standardizedFileURL.path
        for (_, urls) in groups {
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
                let size = (try? fm.attributesOfItem(atPath: primary.path)[.size] as? Int64) ?? 0
                let captureDate = MetadataExtractor.captureDate(for: primary)
                    ?? (try? primary.resourceValues(forKeys: [.creationDateKey]).creationDate)
                result.append(PhotoItem(
                    id: relativePath(of: primary, under: rootPath),
                    primaryURL: primary,
                    pairedURL: paired,
                    captureDate: captureDate,
                    fileSize: size
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
