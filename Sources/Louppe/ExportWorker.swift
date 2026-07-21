import Foundation

/// Filesystem-only Export implementation, CleanUpWorker's shape: it owns no
/// UI state and creates a fresh FileManager inside each call. Copy duplicates
/// files and never touches originals. Move transfers them — RAW+JPEG pairs
/// move or stay together, and a partial failure is rolled back so a pair is
/// never left split between two folders (the result reports if that rollback
/// itself also failed).
enum ExportWorker {
    typealias Progress = CleanUpWorker.Progress

    struct CopyResult: Sendable {
        let copiedFiles: Int
        let failedFiles: Int
    }

    struct MoveResult: Sendable {
        /// Photos whose files *all* reached the destination — SessionStore
        /// drops exactly these ids from the session.
        let movedItemIDs: [String]
        let movedFiles: Int
        /// Photos rolled back and left untouched in the source folder.
        let failedPhotos: Int
        /// Rollback also failed — a pair may be split across both folders.
        let inconsistentPhotos: Int
    }

    static func copy(_ items: [PhotoItem], to destination: URL, progress: @escaping Progress) -> CopyResult {
        let fm = FileManager()
        // Every file to copy: primary file plus its RAW/JPEG partner.
        let sources = items.flatMap(\.allURLs)
        var reporter = ThrottledProgress(total: sources.count, callback: progress)
        var copied = 0
        var failed = 0
        for source in sources {
            let target = collisionFreeURL(for: source.lastPathComponent, in: destination)
            do {
                try fm.copyItem(at: source, to: target)
                copied += 1
            } catch {
                failed += 1
            }
            reporter.advance()
        }
        reporter.finish()
        return CopyResult(copiedFiles: copied, failedFiles: failed)
    }

    static func move(_ items: [PhotoItem], to destination: URL, progress: @escaping Progress) -> MoveResult {
        let fm = FileManager()
        let destinationPath = destination.standardizedFileURL.path
        let total = items.reduce(0) { $0 + $1.allURLs.count }
        var reporter = ThrottledProgress(total: total, callback: progress)
        var movedItemIDs: [String] = []
        var movedFiles = 0
        var failedPhotos = 0
        var inconsistentPhotos = 0

        for item in items {
            let urls = item.allURLs
            var moved: [(source: URL, target: URL)] = []
            var failed = false
            var attempted = 0
            for source in urls {
                attempted += 1
                // "Moving" a file into the folder it already lives in would
                // only rename the original with a collision suffix.
                if source.deletingLastPathComponent().standardizedFileURL.path == destinationPath {
                    failed = true
                    reporter.advance()
                    break
                }
                let target = collisionFreeURL(for: source.lastPathComponent, in: destination)
                do {
                    try fm.moveItem(at: source, to: target)
                    moved.append((source, target))
                } catch {
                    failed = true
                }
                reporter.advance()
                if failed { break }
            }
            if attempted < urls.count { reporter.advance(by: urls.count - attempted) }

            if failed {
                // Put a partially moved pair back exactly where it came from.
                var rollbackFailed = false
                for file in moved.reversed() {
                    do {
                        try fm.moveItem(at: file.target, to: file.source)
                    } catch {
                        rollbackFailed = true
                    }
                }
                failedPhotos += 1
                if rollbackFailed { inconsistentPhotos += 1 }
            } else {
                movedItemIDs.append(item.id)
                movedFiles += moved.count
            }
        }
        reporter.finish()
        return MoveResult(
            movedItemIDs: movedItemIDs,
            movedFiles: movedFiles,
            failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos
        )
    }

    /// `DSC_0001.NEF` → `DSC_0001 (1).NEF` when the name is already taken.
    static func collisionFreeURL(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent(filename)
        if !fm.fileExists(atPath: direct.path) { return direct }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
