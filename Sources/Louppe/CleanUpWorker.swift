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
    let journalFailure: Bool
    let requiresRecovery: Bool
}

struct RestoreBatchResult: Sendable {
    let restored: [CleanUpPhotoSnapshot]
    let lostPhotos: Int
    let inconsistentPhotos: Int
    let journalFailure: Bool
    let requiresRecovery: Bool
}

/// Filesystem-only Clean Up implementation. It owns no UI state and creates a
/// fresh FileManager inside each worker call. RAW+JPEG pairs are rolled back
/// together after a partial failure; the result reports if rollback also fails.
enum CleanUpWorker {
    typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    static func moveToTrash(
        _ photos: [CleanUpPhotoSnapshot],
        journalDirectory: URL? = nil,
        progress: @escaping Progress
    ) -> TrashBatchResult {
        let fm = FileManager()
        let total = photos.reduce(0) { $0 + $1.item.allURLs.count }
        let writer: FileOperationJournal.Writer
        do {
            writer = try FileOperationJournal.start(
                kind: .moveToTrash,
                seeds: photos.flatMap { photo in
                    photo.item.allURLs.map {
                        FileOperationJournal.Seed(
                            itemID: photo.item.id,
                            source: $0,
                            destination: nil
                        )
                    }
                },
                directory: journalDirectory
            )
        } catch {
            return TrashBatchResult(
                succeeded: [],
                failedPhotos: photos.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false
            )
        }
        var reporter = ThrottledProgress(total: total, callback: progress)
        var succeeded: [TrashedPhotoSnapshot] = []
        var failedPhotos = 0
        var inconsistentPhotos = 0
        var journalFailure = false
        var globalFileIndex = 0

        photoLoop: for (photoOffset, photo) in photos.enumerated() {
            let urls = photo.item.allURLs
            let photoFileIndex = globalFileIndex
            globalFileIndex += urls.count
            var trashed: [JournaledTrashedFile] = []
            var failed = false
            var destinationUnknown = false
            var attempted = 0
            for (localFileIndex, url) in urls.enumerated() {
                let fileIndex = photoFileIndex + localFileIndex
                attempted += 1
                do {
                    try writer.mark(.started, fileAt: fileIndex)
                } catch {
                    journalFailure = true
                    failed = true
                }
                var trashURL: NSURL?
                if !failed {
                    do {
                        try fm.trashItem(at: url, resultingItemURL: &trashURL)
                    } catch {
                        failed = true
                    }
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
                let trashedFile = TrashedFile(original: url, trash: landed)
                trashed.append(JournaledTrashedFile(
                    file: trashedFile,
                    index: fileIndex
                ))
                do {
                    try writer.mark(
                        .completed,
                        fileAt: fileIndex,
                        resolvedDestination: landed,
                        identityAt: landed
                    )
                } catch {
                    journalFailure = true
                    failed = true
                    break
                }
            }
            if attempted < urls.count { reporter.advance(by: urls.count - attempted) }

            if failed {
                var rollbackFailed = false
                for entry in trashed.reversed() {
                    do {
                        guard !fm.fileExists(atPath: entry.file.original.path) else {
                            throw CleanUpJournalError.refusesOverwrite
                        }
                        try fm.moveItem(
                            at: entry.file.trash,
                            to: entry.file.original
                        )
                    } catch {
                        rollbackFailed = true
                        continue
                    }
                    do {
                        try writer.mark(.rolledBack, fileAt: entry.index)
                    } catch {
                        journalFailure = true
                    }
                }
                failedPhotos += 1
                if destinationUnknown || rollbackFailed { inconsistentPhotos += 1 }
                if journalFailure {
                    failedPhotos += photos.count - photoOffset - 1
                    break photoLoop
                }
            } else {
                succeeded.append(TrashedPhotoSnapshot(
                    index: photo.index,
                    item: photo.item,
                    files: trashed.map(\.file)
                ))
            }
        }
        reporter.finish()
        let journalFinalized = FileOperationJournal.finalize(
            writer,
            operationIsConsistent: inconsistentPhotos == 0
        )
        if !journalFinalized {
            journalFailure = true
        }
        return TrashBatchResult(
            succeeded: succeeded,
            failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos,
            journalFailure: journalFailure,
            requiresRecovery: inconsistentPhotos > 0 || !journalFinalized
        )
    }

    static func restore(
        _ photos: [TrashedPhotoSnapshot],
        journalDirectory: URL? = nil,
        progress: @escaping Progress
    ) -> RestoreBatchResult {
        let fm = FileManager()
        let orderedPhotos = photos.sorted(by: { $0.index < $1.index })
        let total = orderedPhotos.reduce(0) { $0 + $1.files.count }
        let writer: FileOperationJournal.Writer
        do {
            writer = try FileOperationJournal.start(
                kind: .restoreFromTrash,
                seeds: orderedPhotos.flatMap { photo in
                    photo.files.map {
                        FileOperationJournal.Seed(
                            itemID: photo.item.id,
                            source: $0.original,
                            destination: $0.trash,
                            identityURL: $0.trash
                        )
                    }
                },
                directory: journalDirectory
            )
        } catch {
            return RestoreBatchResult(
                restored: [],
                lostPhotos: photos.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false
            )
        }
        var reporter = ThrottledProgress(total: total, callback: progress)
        var restoredPhotos: [CleanUpPhotoSnapshot] = []
        var lostPhotos = 0
        var inconsistentPhotos = 0
        var journalFailure = false
        var globalFileIndex = 0

        photoLoop: for (photoOffset, photo) in orderedPhotos.enumerated() {
            let photoFileIndex = globalFileIndex
            globalFileIndex += photo.files.count
            var restoredFiles: [JournaledTrashedFile] = []
            var failed = false
            var attempted = 0
            for (localFileIndex, file) in photo.files.enumerated() {
                let fileIndex = photoFileIndex + localFileIndex
                attempted += 1
                do {
                    try writer.mark(.started, fileAt: fileIndex)
                } catch {
                    journalFailure = true
                    failed = true
                }
                if !failed {
                    do {
                        try fm.moveItem(at: file.trash, to: file.original)
                        restoredFiles.append(JournaledTrashedFile(
                            file: file,
                            index: fileIndex
                        ))
                    } catch {
                        failed = true
                    }
                }
                if !failed {
                    do {
                        try writer.mark(
                            .completed,
                            fileAt: fileIndex,
                            identityAt: file.original
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                    }
                }
                reporter.advance()
                if failed { break }
            }
            if attempted < photo.files.count { reporter.advance(by: photo.files.count - attempted) }

            if failed {
                // Put a partially restored pair back exactly where it came from.
                var rollbackFailed = false
                for entry in restoredFiles.reversed() {
                    do {
                        guard !fm.fileExists(atPath: entry.file.trash.path) else {
                            throw CleanUpJournalError.refusesOverwrite
                        }
                        try fm.moveItem(
                            at: entry.file.original,
                            to: entry.file.trash
                        )
                    } catch {
                        rollbackFailed = true
                        continue
                    }
                    do {
                        try writer.mark(.rolledBack, fileAt: entry.index)
                    } catch {
                        journalFailure = true
                    }
                }
                lostPhotos += 1
                if rollbackFailed { inconsistentPhotos += 1 }
                if journalFailure {
                    lostPhotos += orderedPhotos.count - photoOffset - 1
                    break photoLoop
                }
            } else {
                restoredPhotos.append(CleanUpPhotoSnapshot(index: photo.index, item: photo.item))
            }
        }
        reporter.finish()
        let journalFinalized = FileOperationJournal.finalize(
            writer,
            operationIsConsistent: inconsistentPhotos == 0
        )
        if !journalFinalized {
            journalFailure = true
        }
        return RestoreBatchResult(
            restored: restoredPhotos,
            lostPhotos: lostPhotos,
            inconsistentPhotos: inconsistentPhotos,
            journalFailure: journalFailure,
            requiresRecovery: inconsistentPhotos > 0 || !journalFinalized
        )
    }

    private struct JournaledTrashedFile {
        let file: TrashedFile
        let index: Int
    }

    private enum CleanUpJournalError: Error {
        case refusesOverwrite
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
