import Foundation

/// Value snapshots passed from SessionStore to the background filesystem loop.
struct CleanUpPhotoSnapshot: Sendable {
    let index: Int
    let item: PhotoItem
}

struct TrashedFile: Sendable {
    let original: URL
    let trash: URL
    let identity: FileOperationJournal.FileIdentity?

    init(
        original: URL,
        trash: URL,
        identity: FileOperationJournal.FileIdentity? = nil
    ) {
        self.original = original
        self.trash = trash
        self.identity = identity
    }
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
        fileManager: FileManager = FileManager(),
        progress: @escaping Progress
    ) -> TrashBatchResult {
        let fm = fileManager
        let total = photos.reduce(0) {
            $0 + $1.item.individualFiles.count
        }
        guard photos.allSatisfy({ photo in
            photo.item.individualFiles.allSatisfy {
                $0.scannedIdentity != nil
            }
        }) else {
            return TrashBatchResult(
                succeeded: [],
                failedPhotos: photos.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false
            )
        }
        let writer: FileOperationJournal.Writer
        do {
            writer = try FileOperationJournal.start(
                kind: .moveToTrash,
                seeds: photos.flatMap { photo in
                    photo.item.individualFiles.map {
                        FileOperationJournal.Seed(
                            itemID: photo.item.id,
                            source: $0.url,
                            destination: nil,
                            expectedIdentity: $0.scannedIdentity
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
                requiresRecovery:
                    FileOperationJournal.errorRequiresRecovery(error)
            )
        }
        var reporter = ThrottledProgress(total: total, callback: progress)
        var succeeded: [TrashedPhotoSnapshot] = []
        var failedPhotos = 0
        var inconsistentPhotos = 0
        var journalFailure = false
        var globalFileIndex = 0

        photoLoop: for (photoOffset, photo) in photos.enumerated() {
            let files = photo.item.individualFiles
            let urls = files.map(\.url)
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
                    var trashCallAttempted = false
                    do {
                        try writer.requireUnchangedSource(at: fileIndex)
                        trashCallAttempted = true
                        try fm.trashItem(at: url, resultingItemURL: &trashURL)
                        if let landed = trashURL as URL? {
                            try DurableFileIO.syncRenameDirectories(
                                from: url,
                                to: landed,
                                fullSync: true
                            )
                        }
                    } catch {
                        if let landed = trashURL as URL?,
                           fm.fileExists(atPath: landed.path),
                           (try? writer.requirePlannedIdentity(
                            at: fileIndex,
                            fileURL: landed
                           )) != nil,
                           let landedIdentity = try? FileOperationJournal
                            .captureIdentity(at: landed) {
                            trashed.append(JournaledTrashedFile(
                                file: TrashedFile(
                                    original: url,
                                    trash: landed,
                                    identity: landedIdentity
                                ),
                                index: fileIndex
                            ))
                        } else if trashCallAttempted {
                            // A pathname reappearing at the source is not
                            // proof that Trash had no effect: it may be a
                            // same-named replacement. The exact planned inode
                            // must be proved either here or at the returned
                            // Trash URL before the journal can be retired.
                            destinationUnknown =
                                (try? writer.requirePlannedIdentity(
                                    at: fileIndex,
                                    fileURL: url
                                )) == nil
                        }
                        failed = true
                    }
                }
                reporter.advance()
                guard !failed else { break }
                guard let landed = trashURL as URL? else {
                    // FileManager normally returns the Trash destination. If
                    // it moved the file without returning one, there is no
                    // safe URL from which to roll it back or later undo it.
                    destinationUnknown =
                        (try? writer.requirePlannedIdentity(
                            at: fileIndex,
                            fileURL: url
                        )) == nil
                    failed = true
                    break
                }
                do {
                    try writer.requirePlannedIdentity(
                        at: fileIndex,
                        fileURL: landed
                    )
                } catch {
                    destinationUnknown =
                        (try? writer.requirePlannedIdentity(
                            at: fileIndex,
                            fileURL: url
                        )) == nil
                    failed = true
                    break
                }
                let landedIdentity: FileOperationJournal.FileIdentity
                do {
                    landedIdentity = try FileOperationJournal.captureIdentity(
                        at: landed
                    )
                } catch {
                    destinationUnknown =
                        (try? writer.requirePlannedIdentity(
                            at: fileIndex,
                            fileURL: url
                        )) == nil
                    failed = true
                    break
                }
                let trashedFile = TrashedFile(
                    original: url,
                    trash: landed,
                    identity: landedIdentity
                )
                trashed.append(JournaledTrashedFile(
                    file: trashedFile,
                    index: fileIndex
                ))
                do {
                    try writer.mark(
                        .completed,
                        fileAt: fileIndex,
                        resolvedDestination: landed,
                        identityAt: landed,
                        expectedIdentity: landedIdentity
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
                    if !rollbackTrashedFile(
                        entry.file,
                        fileManager: fm
                    ) {
                        rollbackFailed = true
                        continue
                    }
                    guard let sourceFile = files.first(where: {
                        FileOperationJournal.exactPathsEqual(
                            $0.url,
                            entry.file.original
                        )
                    }),
                    (try? sourceFile.refreshScannedIdentityFromDisk()) != nil else {
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
                if destinationUnknown || rollbackFailed || journalFailure {
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
        guard orderedPhotos.allSatisfy({ photo in
            photo.files.allSatisfy { $0.identity != nil }
        }) else {
            return RestoreBatchResult(
                restored: [],
                lostPhotos: photos.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false
            )
        }
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
                            expectedIdentity: $0.identity,
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
                requiresRecovery:
                    FileOperationJournal.errorRequiresRecovery(error)
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
            var mutationAmbiguous = false
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
                        try writer.requirePlannedIdentity(
                            at: fileIndex,
                            fileURL: file.trash,
                            includeStatusChange: true
                        )
                        try ExportWorker.atomicExclusiveRename(
                            from: file.trash,
                            to: file.original
                        )
                        try DurableFileIO.syncRenameDirectories(
                            from: file.trash,
                            to: file.original,
                            fullSync: true
                        )
                        try writer.requirePlannedIdentity(
                            at: fileIndex,
                            fileURL: file.original
                        )
                        guard let sourceFile = photo.item.individualFiles
                            .first(where: {
                                FileOperationJournal.exactPathsEqual(
                                    $0.url,
                                    file.original
                                )
                            }) else {
                            throw CleanUpWorkerError.missingSourceFile
                        }
                        try sourceFile.refreshScannedIdentityFromDisk()
                        restoredFiles.append(JournaledTrashedFile(
                            file: file,
                            index: fileIndex
                        ))
                    } catch {
                        switch reconcileRestoreMove(
                            file,
                            fileIndex: fileIndex,
                            writer: writer,
                            fileManager: fm
                        ) {
                        case .moved:
                            restoredFiles.append(JournaledTrashedFile(
                                file: file,
                                index: fileIndex
                            ))
                        case .unchanged:
                            break
                        case .ambiguous:
                            mutationAmbiguous = true
                        }
                        failed = true
                    }
                }
                if !failed {
                    do {
                        try writer.mark(
                            .completed,
                            fileAt: fileIndex,
                            identityAt: file.original,
                            expectedIdentity: file.identity,
                            // Restoring an inode changes ctime. All other
                            // stable fields still have to match the exact
                            // Trash entry captured for this undo.
                            includeStatusChange: false
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
                    if !rollbackRestoredFile(
                        entry.file,
                        fileManager: fm
                    ) {
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
                if mutationAmbiguous || rollbackFailed {
                    inconsistentPhotos += 1
                }
                if mutationAmbiguous || rollbackFailed || journalFailure {
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

    private enum CleanUpWorkerError: Error {
        case missingSourceFile
    }

    private enum RestoreMoveReconciliation {
        /// The exact trashed file is still at its pre-move path. An occupied
        /// original path is therefore somebody else's file and is untouched.
        case unchanged
        /// The exact trashed file reached the original path. It must be part
        /// of pair rollback even if another file raced into the Trash path.
        case moved
        /// Neither known path contains the expected file. Keep the journal so
        /// recovery can retry instead of guessing from pathnames alone.
        case ambiguous
    }

    /// An exclusive rename either moves the whole file or leaves it in place,
    /// but an error can be observed after the filesystem result is visible.
    /// Reconcile using the scan-time identity rather than path existence:
    /// same-named replacements must never be mistaken for Louppe's file.
    private static func reconcileRestoreMove(
        _ file: TrashedFile,
        fileIndex: Int,
        writer: FileOperationJournal.Writer,
        fileManager: FileManager
    ) -> RestoreMoveReconciliation {
        let originalMatches = fileManager.fileExists(
            atPath: file.original.path
        ) && (try? writer.requirePlannedIdentity(
            at: fileIndex,
            fileURL: file.original
        )) != nil
        if originalMatches {
            return .moved
        }

        // An unmoved Trash file has not crossed a directory boundary, so its
        // status-change timestamp must still match as well as its inode and
        // content metadata. A replacement at this path is ambiguous, not a
        // safe no-op.
        let trashMatches = fileManager.fileExists(
            atPath: file.trash.path
        ) && (try? writer.requirePlannedIdentity(
            at: fileIndex,
            fileURL: file.trash,
            includeStatusChange: true
        )) != nil
        return trashMatches ? .unchanged : .ambiguous
    }

    private static func rollbackTrashedFile(
        _ file: TrashedFile,
        fileManager: FileManager
    ) -> Bool {
        guard let identity = file.identity,
              fileManager.fileExists(atPath: file.trash.path),
              !fileManager.fileExists(atPath: file.original.path),
              (try? FileOperationJournal.requireIdentity(
                identity,
                at: file.trash
              )) != nil else {
            return false
        }
        do {
            try ExportWorker.atomicExclusiveRename(
                from: file.trash,
                to: file.original
            )
            try DurableFileIO.syncRenameDirectories(
                from: file.trash,
                to: file.original,
                fullSync: true
            )
            try FileOperationJournal.requireIdentity(
                identity,
                at: file.original
            )
            return !fileManager.fileExists(atPath: file.trash.path)
        } catch {
            return false
        }
    }

    private static func rollbackRestoredFile(
        _ file: TrashedFile,
        fileManager: FileManager
    ) -> Bool {
        guard let identity = file.identity,
              fileManager.fileExists(atPath: file.original.path),
              !fileManager.fileExists(atPath: file.trash.path),
              (try? FileOperationJournal.requireIdentity(
                identity,
                at: file.original
              )) != nil else {
            return false
        }
        do {
            try ExportWorker.atomicExclusiveRename(
                from: file.original,
                to: file.trash
            )
            try DurableFileIO.syncRenameDirectories(
                from: file.original,
                to: file.trash,
                fullSync: true
            )
            try FileOperationJournal.requireIdentity(
                identity,
                at: file.trash
            )
            return !fileManager.fileExists(atPath: file.original.path)
        } catch {
            return false
        }
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
