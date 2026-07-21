import Foundation

/// Value snapshots passed from SessionStore to the background filesystem loop.
struct CleanUpPhotoSnapshot: Sendable {
    let index: Int
    let item: PhotoItem
}

struct TrashedFile: Sendable {
    let original: URL
    let trash: URL
}

struct TrashedPhotoSnapshot: Sendable {
    let index: Int
    let item: PhotoItem
    let files: [TrashedFile]
}

struct TrashBatchResult: Sendable {
    let succeeded: [TrashedPhotoSnapshot]
    let failedPhotos: Int
    let inconsistentPhotos: Int
}

struct RestoreBatchResult: Sendable {
    let restored: [CleanUpPhotoSnapshot]
    let lostPhotos: Int
    let inconsistentPhotos: Int
}

/// Filesystem-only Clean Up implementation. It owns no UI state and creates a
/// fresh FileManager inside each worker call. RAW+JPEG pairs are rolled back
/// together after a partial failure; the result reports if rollback also fails.
enum CleanUpWorker {
    typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    static func moveToTrash(_ photos: [CleanUpPhotoSnapshot], progress: @escaping Progress) -> TrashBatchResult {
        let fm = FileManager()
        let total = photos.reduce(0) { $0 + $1.item.allURLs.count }
        var reporter = ThrottledProgress(total: total, callback: progress)
        var succeeded: [TrashedPhotoSnapshot] = []
        var failedPhotos = 0
        var inconsistentPhotos = 0

        for photo in photos {
            let urls = photo.item.allURLs
            var trashed: [TrashedFile] = []
            var failed = false
            var destinationUnknown = false
            var attempted = 0
            for url in urls {
                attempted += 1
                var trashURL: NSURL?
                do {
                    try fm.trashItem(at: url, resultingItemURL: &trashURL)
                } catch {
                    failed = true
                }
                reporter.advance()
                guard !failed else { break }
                guard let landed = trashURL as URL? else {
                    // FileManager normally returns the Trash destination. If
                    // it moved the file without returning one, there is no
                    // safe URL from which to roll it back or later undo it.
                    destinationUnknown = !fm.fileExists(atPath: url.path)
                    failed = true
                    break
                }
                trashed.append(TrashedFile(original: url, trash: landed))
            }
            if attempted < urls.count { reporter.advance(by: urls.count - attempted) }

            if failed {
                var rollbackFailed = false
                for file in trashed.reversed() {
                    do {
                        try fm.moveItem(at: file.trash, to: file.original)
                    } catch {
                        rollbackFailed = true
                    }
                }
                failedPhotos += 1
                if destinationUnknown || rollbackFailed { inconsistentPhotos += 1 }
            } else {
                succeeded.append(TrashedPhotoSnapshot(index: photo.index, item: photo.item, files: trashed))
            }
        }
        reporter.finish()
        return TrashBatchResult(
            succeeded: succeeded,
            failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos
        )
    }

    static func restore(_ photos: [TrashedPhotoSnapshot], progress: @escaping Progress) -> RestoreBatchResult {
        let fm = FileManager()
        let total = photos.reduce(0) { $0 + $1.files.count }
        var reporter = ThrottledProgress(total: total, callback: progress)
        var restoredPhotos: [CleanUpPhotoSnapshot] = []
        var lostPhotos = 0
        var inconsistentPhotos = 0

        for photo in photos.sorted(by: { $0.index < $1.index }) {
            var restoredFiles: [TrashedFile] = []
            var failed = false
            var attempted = 0
            for file in photo.files {
                attempted += 1
                do {
                    try fm.moveItem(at: file.trash, to: file.original)
                    restoredFiles.append(file)
                } catch {
                    failed = true
                }
                reporter.advance()
                if failed { break }
            }
            if attempted < photo.files.count { reporter.advance(by: photo.files.count - attempted) }

            if failed {
                // Put a partially restored pair back exactly where it came from.
                var rollbackFailed = false
                for file in restoredFiles.reversed() {
                    do {
                        try fm.moveItem(at: file.original, to: file.trash)
                    } catch {
                        rollbackFailed = true
                    }
                }
                lostPhotos += 1
                if rollbackFailed { inconsistentPhotos += 1 }
            } else {
                restoredPhotos.append(CleanUpPhotoSnapshot(index: photo.index, item: photo.item))
            }
        }
        reporter.finish()
        return RestoreBatchResult(
            restored: restoredPhotos,
            lostPhotos: lostPhotos,
            inconsistentPhotos: inconsistentPhotos
        )
    }

    /// Reconstruct the original ordering in one pass. Positions belonging to a
    /// failed restore are omitted; every unaffected survivor retains its order.
    static func mergeRestoredItems(
        survivors: [PhotoItem],
        allRemovedIndices: Set<Int>,
        restored: [CleanUpPhotoSnapshot]
    ) -> [PhotoItem] {
        let restoredByIndex = Dictionary(uniqueKeysWithValues: restored.map { ($0.index, $0.item) })
        let originalCount = survivors.count + allRemovedIndices.count
        var result: [PhotoItem] = []
        result.reserveCapacity(survivors.count + restored.count)
        var survivorIndex = 0
        for originalIndex in 0..<originalCount {
            if let item = restoredByIndex[originalIndex] {
                result.append(item)
            } else if !allRemovedIndices.contains(originalIndex), survivors.indices.contains(survivorIndex) {
                result.append(survivors[survivorIndex])
                survivorIndex += 1
            }
        }
        return result
    }
}

/// Coalesces per-file progress callbacks (shared by CleanUpWorker and
/// ExportWorker) so near-instant operations don't flood the main actor.
struct ThrottledProgress {
    let total: Int
    let callback: CleanUpWorker.Progress
    private(set) var done = 0
    private var lastReportedDone = 0
    private var lastReport = Date.distantPast

    init(total: Int, callback: @escaping CleanUpWorker.Progress) {
        self.total = total
        self.callback = callback
    }

    mutating func advance(by amount: Int = 1) {
        done = min(done + amount, total)
        let now = Date()
        if done == total || done - lastReportedDone >= 50 || now.timeIntervalSince(lastReport) >= 0.1 {
            callback(done, total)
            lastReportedDone = done
            lastReport = now
        }
    }

    mutating func finish() {
        done = total
        if done != lastReportedDone { callback(done, total) }
    }
}
