import Darwin
import Foundation

/// Filesystem-only Export implementation, CleanUpWorker's shape: it owns no
/// UI state and creates a fresh FileManager inside each call. Copy duplicates
/// files and never touches originals. Copy and Move both reserve one shared
/// collision suffix per photo, so RAW+JPEG partners keep matching basenames.
/// A partial pair failure is rolled back; the result reports if rollback
/// itself also failed.
enum ExportWorker {
    typealias Progress = CleanUpWorker.Progress
    typealias FileCopier = @Sendable (_ source: URL, _ destination: URL) throws -> Void

    struct CopyResult: Sendable {
        let copiedFiles: Int
        /// Photos for which at least one member could not be copied. Any
        /// members already copied for that photo were removed again.
        let failedPhotos: Int
        /// Photos whose partial destination copy could not be removed fully.
        let inconsistentPhotos: Int
        /// The photographer stopped Copy. Photos completed before cancellation
        /// remain at the destination; the in-progress photo is rolled back.
        let cancelled: Bool
        /// The operation was stopped because its durable recovery checkpoint
        /// could not be updated.
        let journalFailure: Bool
        /// An active journal remains and must reconcile the interrupted
        /// operation before another file operation starts. Verified staged or
        /// completed copies are preserved; Move still restores its source state.
        let requiresRecovery: Bool
        /// A concise, user-facing reason for the first failure in the batch.
        let failureMessage: String?
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
        let journalFailure: Bool
        let requiresRecovery: Bool
        let failureMessage: String?
    }

    struct PlannedFile: Sendable, Equatable {
        let source: URL
        let target: URL
        let scannedIdentity: FileOperationJournal.FileIdentity?
    }

    struct PlannedItem: Sendable, Equatable {
        let itemID: String
        let files: [PlannedFile]
    }

    struct Plan: Sendable, Equatable {
        let items: [PlannedItem]
        var totalFiles: Int { items.reduce(0) { $0 + $1.files.count } }
    }

    /// A cross-thread cancellation signal owned by ExportManager. It is used
    /// only for Copy: Move must finish or roll back before session state can
    /// safely change.
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

    /// Reserves every destination name before file I/O. If any member of a
    /// photo collides, all members receive the same numeric suffix. The
    /// reservation set also prevents two same-named photos from different
    /// source subfolders colliding with each other in the same export batch.
    static func makePlan(
        for items: [PhotoItem],
        in destination: URL
    ) throws -> Plan {
        var reservedPaths: Set<String> = []
        var plannedItems: [PlannedItem] = []
        plannedItems.reserveCapacity(items.count)

        for item in items {
            let sources = item.individualFiles
            var suffix = 0
            while true {
                let targetNames = sources.map {
                    suffixedFilename(
                        $0.url.lastPathComponent,
                        suffix: suffix
                    )
                }
                let targets = try targetNames.map {
                    try FileOperationJournal.appendingPathComponentExactly(
                        $0,
                        to: destination
                    )
                }
                let normalizedPaths = targetNames.map(normalizedReservationName)
                let targetsAreDistinct = Set(normalizedPaths).count == normalizedPaths.count
                let areAvailable = targetsAreDistinct && zip(targets, normalizedPaths).allSatisfy {
                    !pathEntryExists($0.0) && !reservedPaths.contains($0.1)
                }
                if areAvailable {
                    reservedPaths.formUnion(normalizedPaths)
                    plannedItems.append(PlannedItem(
                        itemID: item.id,
                        files: zip(sources, targets).map {
                            PlannedFile(
                                source: $0.0.url,
                                target: $0.1,
                                scannedIdentity: $0.0.scannedIdentity
                            )
                        }
                    ))
                    break
                }
                suffix += 1
            }
        }
        return Plan(items: plannedItems)
    }

    static func copy(
        _ items: [PhotoItem],
        to destination: URL,
        journalDirectory: URL? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        fileCopier: @escaping FileCopier = { source, destination in
            try FileManager().copyItem(at: source, to: destination)
        },
        afterStagedFile: (Int) -> Void = { _ in },
        progress: @escaping Progress
    ) -> CopyResult {
        let fm = FileManager()
        let plan: Plan
        do {
            plan = try makePlan(for: items, in: destination)
        } catch {
            return CopyResult(
                copiedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                cancelled: false,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: copyFailureMessage(
                    for: error,
                    phase: .planning
                )
            )
        }
        guard plan.items.allSatisfy({ item in
            item.files.allSatisfy { $0.scannedIdentity != nil }
        }) else {
            return CopyResult(
                copiedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                cancelled: false,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: "One or more source files could not be verified before copying"
            )
        }
        let writer: FileOperationJournal.Writer
        do {
            writer = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: plan.items.flatMap { item in
                    item.files.map {
                        FileOperationJournal.Seed(
                            itemID: item.itemID,
                            source: $0.source,
                            destination: $0.target,
                            expectedIdentity: $0.scannedIdentity
                        )
                    }
                },
                directory: journalDirectory
            )
        } catch {
            return CopyResult(
                copiedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                cancelled: false,
                journalFailure: true,
                requiresRecovery:
                    FileOperationJournal.errorRequiresRecovery(error),
                failureMessage: copyFailureMessage(
                    for: error,
                    phase: .safetyRecord
                )
            )
        }
        var reporter = ThrottledProgress(total: plan.totalFiles, callback: progress)
        var copied = 0
        var failedPhotos = 0
        var inconsistentPhotos = 0
        var cancelled = false
        var journalFailure = false
        var failureMessage: String?
        var sourceUnavailable = false
        var globalFileIndex = 0

        itemLoop: for (itemOffset, item) in plan.items.enumerated() {
            let itemFileIndex = globalFileIndex
            globalFileIndex += item.files.count
            if isCancelled() {
                cancelled = true
                break
            }
            var touchedForItem: [TouchedExportFile] = []
            var failed = false
            var attempted = 0
            for (localFileIndex, file) in item.files.enumerated() {
                let fileIndex = itemFileIndex + localFileIndex
                if isCancelled() {
                    cancelled = true
                    failed = true
                    break
                }
                attempted += 1
                var touched = TouchedExportFile(
                    file: file,
                    index: fileIndex,
                    location: .none,
                    identity: nil
                )
                guard let temporary = writer.temporaryURL(at: fileIndex) else {
                    journalFailure = true
                    failed = true
                    failureMessage = failureMessage
                        ?? "Louppe could not resolve its protected temporary copy path"
                    touchedForItem.append(touched)
                    reporter.advance()
                    break
                }
                do {
                    try writer.mark(.started, fileAt: fileIndex)
                } catch {
                    journalFailure = true
                    failed = true
                    failureMessage = failureMessage ?? copyFailureMessage(
                        for: error,
                        phase: .safetyRecord
                    )
                }
                if !failed {
                    do {
                        try copySourceWithReconnectRetry(
                            writer: writer,
                            fileIndex: fileIndex,
                            source: file.source,
                            temporary: temporary,
                            isCancelled: isCancelled,
                            fileCopier: fileCopier
                        )
                        touched.location = .temporary(temporary)
                        touched.identity = try FileOperationJournal
                            .captureIdentity(at: temporary)
                        try DurableFileIO.syncFile(
                            at: temporary,
                            fullSync: true
                        )
                        try DurableFileIO.syncDirectory(
                            temporary.deletingLastPathComponent(),
                            fullSync: true
                        )
                        // Detect an in-place source rewrite that raced with
                        // the copy. Rollback will only remove the duplicate
                        // after proving the source still is the scanned file
                        // and both files remain byte-for-byte equal.
                        try requireSourceAfterReconnect(
                            writer: writer,
                            fileIndex: fileIndex,
                            source: file.source,
                            allowCancellation: false,
                            isCancelled: isCancelled
                        )
                    } catch {
                        if case SourceReconnectError.cancelled = error {
                            cancelled = true
                        }
                        if !cancelled, failureMessage == nil {
                            failureMessage = copyFailureMessage(
                                for: error,
                                phase: .readingSource
                            )
                        }
                        if isUnavailableSourceError(error) {
                            sourceUnavailable = true
                        }
                        if case .none = touched.location,
                           pathEntryExists(temporary) {
                            // `copyItem` may leave a partial regular file when
                            // it throws. Record that exact inode before doing
                            // anything else so rollback can remove only the
                            // operation-created artifact, never a late file
                            // that merely appears at the same pathname.
                            do {
                                let partialIdentity = try FileOperationJournal
                                    .captureIdentity(at: temporary)
                                try writer.mark(
                                    .started,
                                    fileAt: fileIndex,
                                    identityAt: temporary,
                                    expectedIdentity: partialIdentity,
                                    includeStatusChange: false
                                )
                                touched.location = .temporary(temporary)
                                touched.identity = partialIdentity
                                touched.isIncompleteCopy = true
                            } catch {
                                journalFailure = true
                                touched.location = .ambiguous
                            }
                        }
                        failed = true
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: temporary,
                            includeStatusChange: false
                        )
                        try writer.mark(
                            .staged,
                            fileAt: fileIndex,
                            identityAt: temporary,
                            expectedIdentity: identity,
                            includeStatusChange: false
                        )
                        afterStagedFile(fileIndex)
                    } catch {
                        journalFailure = true
                        failed = true
                        failureMessage = failureMessage ?? copyFailureMessage(
                            for: error,
                            phase: .safetyRecord
                        )
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: temporary,
                            includeStatusChange: false
                        )
                        try atomicExclusiveRename(
                            from: temporary,
                            to: file.target
                        )
                        touched.location = .destination
                        try DurableFileIO.syncRenameDirectories(
                            from: temporary,
                            to: file.target,
                            fullSync: true
                        )
                        touched.identity = try verifiedIdentity(
                            matching: identity,
                            at: file.target
                        )
                    } catch {
                        failureMessage = failureMessage ?? copyFailureMessage(
                            for: error,
                            phase: .publishingDestination
                        )
                        if let identity = touched.identity {
                            let reconciled = reconcileExportRename(
                                expectedIdentity: identity,
                                source: temporary,
                                destination: file.target,
                                sourceLocation: .temporary(temporary),
                                destinationLocation: .destination
                            )
                            touched.location = reconciled.location
                            touched.identity = reconciled.identity
                        } else {
                            touched.location = .ambiguous
                        }
                        failed = true
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        // The source was revalidated after copyItem and before
                        // the durable staged checkpoint. Do not consult it again:
                        // an HDD can be ejected after a valid copy has completed,
                        // and that must not turn success into destructive rollback.
                        try requireIdentity(
                            identity,
                            at: file.target,
                            includeStatusChange: false
                        )
                        try writer.mark(
                            .completed,
                            fileAt: fileIndex,
                            identityAt: file.target,
                            expectedIdentity: identity,
                            includeStatusChange: false
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                        failureMessage = failureMessage ?? copyFailureMessage(
                            for: error,
                            phase: .safetyRecord
                        )
                    }
                }
                touchedForItem.append(touched)
                reporter.advance()
                if failed { break }
            }
            if attempted < item.files.count {
                reporter.advance(by: item.files.count - attempted)
            }

            if failed {
                var rollbackFailed = false
                for touched in touchedForItem.reversed() {
                    if !rollbackCopy(
                        touched,
                        temporary: writer.temporaryURL(at: touched.index),
                        fileManager: fm
                    ) {
                        rollbackFailed = true
                    } else if (try? writer.mark(.rolledBack, fileAt: touched.index)) == nil {
                        journalFailure = true
                    }
                }
                if !cancelled { failedPhotos += 1 }
                if rollbackFailed { inconsistentPhotos += 1 }
                if cancelled { break }
                if sourceUnavailable {
                    failedPhotos += plan.items.count - itemOffset - 1
                    break itemLoop
                }
                if rollbackFailed || journalFailure {
                    failedPhotos += plan.items.count - itemOffset - 1
                    break itemLoop
                }
            } else {
                copied += touchedForItem.count
            }
        }
        if !cancelled { reporter.finish() }
        let journalFinalized = FileOperationJournal.finalize(
            writer,
            operationIsConsistent: inconsistentPhotos == 0
        )
        if !journalFinalized {
            journalFailure = true
            failureMessage = failureMessage
                ?? "Louppe could not seal the completed file-safety record"
        }
        return CopyResult(
            copiedFiles: copied,
            failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos,
            cancelled: cancelled,
            journalFailure: journalFailure,
            requiresRecovery: inconsistentPhotos > 0 || !journalFinalized,
            failureMessage: failureMessage
        )
    }

    static func move(
        _ items: [PhotoItem],
        to destination: URL,
        journalDirectory: URL? = nil,
        progress: @escaping Progress
    ) -> MoveResult {
        // Defense in depth: the dialog preflight explains this limitation,
        // while the worker independently refuses any caller that would make
        // FileManager perform an implicit, uncheckpointed copy/delete move.
        guard ExportDestinationValidator.moveCanUseAtomicRename(
            items: items,
            destination: destination
        ) else {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: false,
                requiresRecovery: false,
                failureMessage: "Move requires the source and destination to be on the same storage volume"
            )
        }
        let fm = FileManager()
        let sourceFiles = items.flatMap(\.individualFiles)
        let sourcePathPairs = sourceFiles.compactMap { file in
            FileOperationJournal.exactPathBytes(for: file.url).map {
                ($0, file)
            }
        }
        let sourceFilesByPath = Dictionary(
            sourcePathPairs,
            uniquingKeysWith: { first, _ in first }
        )
        guard sourcePathPairs.count == sourceFiles.count,
              sourceFilesByPath.count == sourceFiles.count else {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: "Louppe could not preserve the exact source paths safely"
            )
        }
        let plan: Plan
        do {
            plan = try makePlan(for: items, in: destination)
        } catch {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: copyFailureMessage(
                    for: error,
                    phase: .planning
                )
            )
        }
        guard plan.items.allSatisfy({ item in
            item.files.allSatisfy { $0.scannedIdentity != nil }
        }) else {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: "One or more source files could not be verified before moving"
            )
        }
        let writer: FileOperationJournal.Writer
        do {
            writer = try FileOperationJournal.start(
                kind: .exportMove,
                seeds: plan.items.flatMap { item in
                    item.files.map {
                        FileOperationJournal.Seed(
                            itemID: item.itemID,
                            source: $0.source,
                            destination: $0.target,
                            expectedIdentity: $0.scannedIdentity
                        )
                    }
                },
                directory: journalDirectory
            )
        } catch {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery:
                    FileOperationJournal.errorRequiresRecovery(error),
                failureMessage: copyFailureMessage(
                    for: error,
                    phase: .safetyRecord
                )
            )
        }
        var reporter = ThrottledProgress(total: plan.totalFiles, callback: progress)
        var movedItemIDs: [String] = []
        var movedFiles = 0
        var failedPhotos = 0
        var inconsistentPhotos = 0
        var journalFailure = false
        var globalFileIndex = 0

        itemLoop: for (itemOffset, item) in plan.items.enumerated() {
            let itemFileIndex = globalFileIndex
            globalFileIndex += item.files.count
            var touchedForItem: [TouchedExportFile] = []
            var failed = false
            var attempted = 0
            for (localFileIndex, file) in item.files.enumerated() {
                let fileIndex = itemFileIndex + localFileIndex
                attempted += 1
                var touched = TouchedExportFile(
                    file: file,
                    index: fileIndex,
                    location: .none,
                    identity: nil
                )
                // "Moving" a file into the folder it already lives in would
                // only rename the original with a collision suffix.
                if ExportDestinationValidator.directoriesReferToSameEntry(
                    file.source.deletingLastPathComponent(),
                    destination
                ) {
                    failed = true
                    reporter.advance()
                    touchedForItem.append(touched)
                    break
                }
                guard let temporary = writer.temporaryURL(at: fileIndex) else {
                    journalFailure = true
                    failed = true
                    touchedForItem.append(touched)
                    reporter.advance()
                    break
                }
                do {
                    try writer.mark(.started, fileAt: fileIndex)
                } catch {
                    journalFailure = true
                    failed = true
                }
                if !failed {
                    var renamedToTemporary = false
                    do {
                        try writer.requireUnchangedSource(at: fileIndex)
                        try atomicExclusiveRename(
                            from: file.source,
                            to: temporary
                        )
                        renamedToTemporary = true
                        touched.location = .temporary(temporary)
                        try DurableFileIO.syncRenameDirectories(
                            from: file.source,
                            to: temporary,
                            fullSync: true
                        )
                        touched.identity = try verifiedIdentity(
                            matching: writer.plannedIdentity(at: fileIndex),
                            at: temporary
                        )
                    } catch {
                        if renamedToTemporary {
                            let reconciled = reconcileFirstMoveRename(
                                writer: writer,
                                fileIndex: fileIndex,
                                source: file.source,
                                temporary: temporary
                            )
                            touched.location = reconciled.location
                            touched.identity = reconciled.identity
                        }
                        failed = true
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: temporary,
                            includeStatusChange: true
                        )
                        try writer.mark(
                            .staged,
                            fileAt: fileIndex,
                            identityAt: temporary,
                            expectedIdentity: identity
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                    }
                }
                if !failed {
                    var renamedToDestination = false
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: temporary,
                            includeStatusChange: true
                        )
                        try atomicExclusiveRename(
                            from: temporary,
                            to: file.target
                        )
                        renamedToDestination = true
                        touched.location = .destination
                        try DurableFileIO.syncRenameDirectories(
                            from: temporary,
                            to: file.target,
                            fullSync: true
                        )
                        touched.identity = try verifiedIdentity(
                            matching: identity,
                            at: file.target
                        )
                    } catch {
                        if renamedToDestination,
                           let identity = touched.identity {
                            let reconciled = reconcileExportRename(
                                expectedIdentity: identity,
                                source: temporary,
                                destination: file.target,
                                sourceLocation: .temporary(temporary),
                                destinationLocation: .destination
                            )
                            touched.location = reconciled.location
                            touched.identity = reconciled.identity
                        } else if touched.identity == nil {
                            touched.location = .ambiguous
                        }
                        failed = true
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: file.target,
                            includeStatusChange: true
                        )
                        try writer.mark(
                            .completed,
                            fileAt: fileIndex,
                            identityAt: file.target,
                            expectedIdentity: identity
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                    }
                }
                touchedForItem.append(touched)
                reporter.advance()
                if failed { break }
            }
            if attempted < item.files.count {
                reporter.advance(by: item.files.count - attempted)
            }

            if failed {
                // Put a partially moved pair back exactly where it came from.
                var rollbackFailed = false
                for touched in touchedForItem.reversed() {
                    if !rollbackMove(touched, fileManager: fm) {
                        rollbackFailed = true
                    } else {
                        if touched.needsSourceIdentityRefresh {
                            guard let sourcePath = FileOperationJournal
                                .exactPathBytes(for: touched.file.source),
                            let sourceFile = sourceFilesByPath[sourcePath],
                            (try? sourceFile.refreshScannedIdentityFromDisk()) != nil else {
                                rollbackFailed = true
                                continue
                            }
                        }
                        if (try? writer.mark(
                            .rolledBack,
                            fileAt: touched.index
                        )) == nil {
                            journalFailure = true
                        }
                    }
                }
                failedPhotos += 1
                if rollbackFailed { inconsistentPhotos += 1 }
                if rollbackFailed || journalFailure {
                    failedPhotos += plan.items.count - itemOffset - 1
                    break itemLoop
                }
            } else {
                movedItemIDs.append(item.itemID)
                movedFiles += touchedForItem.count
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
        return MoveResult(
            movedItemIDs: movedItemIDs,
            movedFiles: movedFiles,
            failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos,
            journalFailure: journalFailure,
            requiresRecovery: inconsistentPhotos > 0 || !journalFinalized,
            failureMessage: failedPhotos > 0 || journalFailure
                ? "A source, destination, or file-safety checkpoint became unavailable during the move"
                : nil
        )
    }

    private enum ExportFileLocation {
        case none
        case temporary(URL)
        case destination
        case ambiguous
    }

    private struct TouchedExportFile {
        let file: PlannedFile
        let index: Int
        var location: ExportFileLocation
        var identity: FileOperationJournal.FileIdentity?
        var isIncompleteCopy = false

        var needsSourceIdentityRefresh: Bool {
            switch location {
            case .none, .ambiguous:
                return false
            case .temporary, .destination:
                return true
            }
        }
    }

    private static func rollbackCopy(
        _ touched: TouchedExportFile,
        temporary: URL?,
        fileManager: FileManager
    ) -> Bool {
        let artifact: URL?
        let quarantine: URL?
        switch touched.location {
        case .none:
            artifact = nil
            quarantine = nil
        case .temporary(let url):
            artifact = url
            quarantine = touched.file.target
        case .destination:
            artifact = touched.file.target
            quarantine = temporary
        case .ambiguous:
            return false
        }
        guard let artifact else { return true }
        guard let quarantine,
              let artifactIdentity = touched.identity,
              let sourceIdentity = touched.file.scannedIdentity else {
            return false
        }
        if touched.isIncompleteCopy {
            return removeRecordedPartialCopy(
                artifact: artifact,
                quarantine: quarantine,
                artifactIdentity: artifactIdentity
            )
        }
        return removeVerifiedCopy(
            source: touched.file.source,
            artifact: artifact,
            quarantine: quarantine,
            sourceIdentity: sourceIdentity,
            artifactIdentity: artifactIdentity,
            fileManager: fileManager
        )
    }

    /// A Copy rollback first transfers the candidate between the two paths
    /// already reserved by the immutable journal plan. Re-verifying after that
    /// exclusive rename means a late replacement is preserved, while a crash
    /// still leaves the copy at a pathname recovery already understands.
    private static func removeVerifiedCopy(
        source: URL,
        artifact: URL,
        quarantine: URL,
        sourceIdentity: FileOperationJournal.FileIdentity,
        artifactIdentity: FileOperationJournal.FileIdentity,
        fileManager: FileManager,
        afterComparison: () -> Void = {}
    ) -> Bool {
        guard !FileOperationJournal.exactPathsEqual(
                artifact,
                quarantine
              ),
              pathEntryExists(artifact),
              pathEntryExists(source),
              !pathEntryExists(quarantine) else {
            return false
        }
        do {
            try requireIdentity(
                sourceIdentity,
                at: source,
                includeStatusChange: true
            )
            try requireIdentity(
                artifactIdentity,
                at: artifact,
                includeStatusChange: false
            )
            guard FileOperationJournal.contentsEqual(
                source,
                artifact
            ) else { return false }
            afterComparison()
            // Both halves of the safety proof may have changed during the
            // potentially long byte comparison. The original must still be
            // exact before its duplicate can be removed.
            try requireIdentity(
                sourceIdentity,
                at: source,
                includeStatusChange: true
            )
            try requireIdentity(
                artifactIdentity,
                at: artifact,
                includeStatusChange: false
            )
            try atomicExclusiveRename(from: artifact, to: quarantine)
            try DurableFileIO.syncRenameDirectories(
                from: artifact,
                to: quarantine,
                fullSync: true
            )
            // Rename changes ctime. Capture that new value, prove the
            // remaining stable fields still identify the owned copy, then
            // repeat the potentially long byte comparison. The exact fresh
            // identities must still hold after that second comparison.
            let quarantinedIdentity = try FileOperationJournal
                .captureIdentity(at: quarantine)
            guard FileOperationJournal.identitiesMatch(
                expected: artifactIdentity,
                actual: quarantinedIdentity,
                includeStatusChange: false
            ) else { return false }
            guard FileOperationJournal.contentsEqual(
                source,
                quarantine
            ) else { return false }
            try requireIdentity(
                sourceIdentity,
                at: source,
                includeStatusChange: true
            )
            try requireIdentity(
                quarantinedIdentity,
                at: quarantine,
                includeStatusChange: false
            )
            try DurableFileIO.unlinkRegularFile(at: quarantine)
            try DurableFileIO.syncRemoval(of: quarantine, fullSync: true)
            return !pathEntryExists(artifact) && !pathEntryExists(quarantine)
        } catch {
            return false
        }
    }

    /// Removes a failed `copyItem` artifact only after the `.started`
    /// checkpoint has captured its physical identity. The exclusive rename
    /// closes the replacement race: if another entry appears at the reserved
    /// path, both files are preserved and recovery remains retryable.
    private static func removeRecordedPartialCopy(
        artifact: URL,
        quarantine: URL,
        artifactIdentity: FileOperationJournal.FileIdentity
    ) -> Bool {
        guard !FileOperationJournal.exactPathsEqual(artifact, quarantine),
              pathEntryExists(artifact),
              !pathEntryExists(quarantine) else {
            return false
        }
        do {
            try requireIdentity(
                artifactIdentity,
                at: artifact,
                includeStatusChange: false
            )
            try atomicExclusiveRename(from: artifact, to: quarantine)
            try DurableFileIO.syncRenameDirectories(
                from: artifact,
                to: quarantine,
                fullSync: true
            )
            let quarantinedIdentity = try FileOperationJournal
                .captureIdentity(at: quarantine)
            guard FileOperationJournal.identitiesMatch(
                expected: artifactIdentity,
                actual: quarantinedIdentity,
                includeStatusChange: false
            ) else { return false }
            try requireIdentity(
                quarantinedIdentity,
                at: quarantine,
                includeStatusChange: false
            )
            try DurableFileIO.unlinkRegularFile(at: quarantine)
            try DurableFileIO.syncRemoval(of: quarantine, fullSync: true)
            return !pathEntryExists(artifact) && !pathEntryExists(quarantine)
        } catch {
            return false
        }
    }

#if DEBUG
    static func removeVerifiedCopyForTesting(
        source: URL,
        artifact: URL,
        quarantine: URL,
        sourceIdentity: FileOperationJournal.FileIdentity,
        artifactIdentity: FileOperationJournal.FileIdentity,
        afterComparison: () -> Void
    ) -> Bool {
        removeVerifiedCopy(
            source: source,
            artifact: artifact,
            quarantine: quarantine,
            sourceIdentity: sourceIdentity,
            artifactIdentity: artifactIdentity,
            fileManager: .default,
            afterComparison: afterComparison
        )
    }
#endif

    private static func rollbackMove(
        _ touched: TouchedExportFile,
        fileManager: FileManager
    ) -> Bool {
        let movedURL: URL?
        switch touched.location {
        case .none:
            movedURL = nil
        case .temporary(let url):
            movedURL = url
        case .destination:
            movedURL = touched.file.target
        case .ambiguous:
            return false
        }
        guard let movedURL else { return true }
        guard let identity = touched.identity else { return false }
        return restoreMovedFile(
            from: movedURL,
            to: touched.file.source,
            expectedIdentity: identity,
            fileManager: fileManager
        )
    }

    /// A touched Move file disappearing from its expected path is
    /// inconsistent, not a successful rollback. Retaining the journal is the
    /// only safe response when a destination directory was renamed/swapped.
    static func restoreMovedFile(
        from movedURL: URL,
        to source: URL,
        expectedIdentity: FileOperationJournal.FileIdentity? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard pathEntryExists(movedURL),
              !pathEntryExists(source) else {
            return false
        }
        do {
            if let expectedIdentity {
                try requireIdentity(
                    expectedIdentity,
                    at: movedURL,
                    includeStatusChange: true
                )
            }
            try atomicExclusiveRename(from: movedURL, to: source)
            try DurableFileIO.syncRenameDirectories(
                from: movedURL,
                to: source,
                fullSync: true
            )
            if let expectedIdentity {
                try requireIdentity(
                    expectedIdentity,
                    at: source,
                    includeStatusChange: false
                )
            }
            return !pathEntryExists(movedURL)
        } catch {
            return false
        }
    }

    private struct ReconciledLocation {
        let location: ExportFileLocation
        let identity: FileOperationJournal.FileIdentity?
    }

    /// Determines where an inode-preserving rename landed after an error. An
    /// unrelated file racing into the other path is preserved; only the path
    /// that still carries the exact operation-owned identity is rolled back.
    private static func reconcileExportRename(
        expectedIdentity: FileOperationJournal.FileIdentity,
        source: URL,
        destination: URL,
        sourceLocation: ExportFileLocation,
        destinationLocation: ExportFileLocation
    ) -> ReconciledLocation {
        let sourceIdentity = matchingIdentity(
            expectedIdentity,
            at: source,
            includeStatusChange: true
        )
        let destinationIdentity = matchingIdentity(
            expectedIdentity,
            at: destination,
            includeStatusChange: false
        )
        switch (sourceIdentity, destinationIdentity) {
        case (.some(let identity), .none):
            return ReconciledLocation(
                location: sourceLocation,
                identity: identity
            )
        case (.none, .some(let identity)):
            return ReconciledLocation(
                location: destinationLocation,
                identity: identity
            )
        default:
            return ReconciledLocation(location: .ambiguous, identity: nil)
        }
    }

    private static func reconcileFirstMoveRename(
        writer: FileOperationJournal.Writer,
        fileIndex: Int,
        source: URL,
        temporary: URL
    ) -> ReconciledLocation {
        guard let planned = try? writer.plannedIdentity(at: fileIndex) else {
            return ReconciledLocation(location: .ambiguous, identity: nil)
        }
        let sourceIdentity = matchingIdentity(
            planned,
            at: source,
            includeStatusChange: true
        )
        let temporaryIdentity = matchingIdentity(
            planned,
            at: temporary,
            includeStatusChange: false
        )
        switch (sourceIdentity, temporaryIdentity) {
        case (.some, .none):
            return ReconciledLocation(location: .none, identity: nil)
        case (.none, .some(let identity)):
            return ReconciledLocation(
                location: .temporary(temporary),
                identity: identity
            )
        default:
            return ReconciledLocation(location: .ambiguous, identity: nil)
        }
    }

    private static func verifiedIdentity(
        matching expected: FileOperationJournal.FileIdentity,
        at url: URL
    ) throws -> FileOperationJournal.FileIdentity {
        let actual = try FileOperationJournal.captureIdentity(at: url)
        guard FileOperationJournal.identitiesMatch(
            expected: expected,
            actual: actual,
            includeStatusChange: false
        ) else {
            throw ExportWorkerError.copiedFileChanged
        }
        return actual
    }

    private static func matchingIdentity(
        _ expected: FileOperationJournal.FileIdentity,
        at url: URL,
        includeStatusChange: Bool
    ) -> FileOperationJournal.FileIdentity? {
        guard let actual = try? FileOperationJournal.captureIdentity(at: url),
              FileOperationJournal.identitiesMatch(
                expected: expected,
                actual: actual,
                includeStatusChange: includeStatusChange
              ) else {
            return nil
        }
        return actual
    }

    private static func requireIdentity(
        _ expected: FileOperationJournal.FileIdentity,
        at url: URL,
        includeStatusChange: Bool
    ) throws {
        try FileOperationJournal.requireIdentity(
            expected,
            at: url,
            includeStatusChange: includeStatusChange
        )
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        var info = Darwin.stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &info) == 0
        }
    }

    /// `FileManager.copyItem` can return as soon as a sleeping Mac wakes,
    /// several seconds before an external source volume has mounted again.
    /// Retry one untouched temporary copy after the exact scanned source
    /// identity reappears. A partial temporary artifact is never guessed away:
    /// it stays under the journal's conservative recovery rules.
    private static func copySourceWithReconnectRetry(
        writer: FileOperationJournal.Writer,
        fileIndex: Int,
        source: URL,
        temporary: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        fileCopier: @escaping FileCopier
    ) throws {
        do {
            try writer.requireUnchangedSource(at: fileIndex)
            try fileCopier(source, temporary)
            return
        } catch {
            guard isTransientSourceError(error),
                  !pathEntryExists(temporary) else {
                throw error
            }
            // A missing individual file on a still-mounted volume is not a
            // remount delay (it may have been moved or replaced). Only wait
            // when the planned volume root itself disappeared. A source that
            // is still present may retry one transient read/I/O error now.
            if !pathEntryExists(source),
               !plannedSourceVolumeIsUnavailable(
                    writer: writer,
                    fileIndex: fileIndex
               ) {
                throw error
            }
        }

        try requireSourceAfterReconnect(
            writer: writer,
            fileIndex: fileIndex,
            source: source,
            allowCancellation: true,
            isCancelled: isCancelled
        )
        do {
            try fileCopier(source, temporary)
        } catch {
            if isTransientSourceError(error) {
                throw SourceReconnectError.unavailable(error)
            }
            throw error
        }
    }

    /// Waits for at most one minute of *awake* polling. `Thread.sleep` pauses
    /// with the process during system sleep, so closing the lid for a long time
    /// does not consume the remount grace period before the Mac wakes.
    private static func requireSourceAfterReconnect(
        writer: FileOperationJournal.Writer,
        fileIndex: Int,
        source: URL,
        allowCancellation: Bool,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        var lastError: Error?
        for attempt in 0..<240 {
            do {
                try writer.requireUnchangedSource(at: fileIndex)
                return
            } catch {
                lastError = error
                // A file exists but does not match the scan identity. This is
                // a replacement, not a slow removable-volume remount.
                if pathEntryExists(source) { throw error }
                // Likewise, a missing individual path on an otherwise mounted
                // volume is a real session change, not a reconnect window.
                if !plannedSourceVolumeIsUnavailable(
                    writer: writer,
                    fileIndex: fileIndex
                ) {
                    throw error
                }
            }
            if allowCancellation, isCancelled() {
                throw SourceReconnectError.cancelled
            }
            if attempt < 239 {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw SourceReconnectError.unavailable(
            lastError ?? ExportWorkerError.missingTouchedIdentity
        )
    }

    private static func plannedSourceVolumeIsUnavailable(
        writer: FileOperationJournal.Writer,
        fileIndex: Int
    ) -> Bool {
        guard let identity = try? writer.plannedIdentity(at: fileIndex) else {
            return false
        }
        return !pathEntryExists(
            URL(fileURLWithPath: identity.volumeRootPath, isDirectory: true)
        )
    }

    private static func isUnavailableSourceError(_ error: Error) -> Bool {
        if case SourceReconnectError.unavailable = error { return true }
        return false
    }

    private static func isTransientSourceError(_ error: Error) -> Bool {
        if let journalError = error as? FileOperationJournal.JournalError,
           case .missingFileIdentity = journalError {
            return true
        }
        for candidate in errorChain(error) {
            if candidate.domain == NSPOSIXErrorDomain,
               [ENOENT, EIO, ENXIO, ENODEV, ESTALE, ETIMEDOUT]
                .contains(Int32(candidate.code)) {
                return true
            }
            if candidate.domain == NSCocoaErrorDomain,
               [NSFileReadUnknownError, NSFileReadNoSuchFileError]
                .contains(candidate.code) {
                return true
            }
        }
        return false
    }

    private static func errorChain(_ error: Error) -> [NSError] {
        var result: [NSError] = []
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        while let candidate = current,
              seen.insert(ObjectIdentifier(candidate)).inserted {
            result.append(candidate)
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    private enum CopyFailurePhase {
        case planning
        case readingSource
        case publishingDestination
        case safetyRecord
    }

    private static func copyFailureMessage(
        for error: Error,
        phase: CopyFailurePhase
    ) -> String {
        if isUnavailableSourceError(error) {
            return "The source drive disconnected and did not remount in time"
        }
        let chain = errorChain(error)
        if chain.contains(where: {
            $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC)
        }) || chain.contains(where: {
            $0.domain == NSCocoaErrorDomain
                && $0.code == NSFileWriteOutOfSpaceError
        }) {
            return "The destination ran out of free space"
        }
        if chain.contains(where: {
            $0.domain == NSPOSIXErrorDomain
                && [Int(EACCES), Int(EPERM), Int(EROFS)].contains($0.code)
        }) {
            return phase == .readingSource
                ? "The source file could no longer be read"
                : "The destination could no longer be written"
        }
        switch phase {
        case .planning:
            return "Louppe could not create a safe export plan: \(error.localizedDescription)"
        case .readingSource:
            return "A source file could not be copied: \(error.localizedDescription)"
        case .publishingDestination:
            return "A completed copy could not be published at the destination: \(error.localizedDescription)"
        case .safetyRecord:
            return "Louppe could not advance its durable file-safety record: \(error.localizedDescription)"
        }
    }

    private enum SourceReconnectError: Error {
        case cancelled
        case unavailable(Error)
    }

    private enum ExportWorkerError: Error {
        case missingTouchedIdentity
        case copiedFileChanged
    }

    /// Exclusive POSIX rename is the Move correctness boundary: unlike
    /// `FileManager.moveItem`, it can never fall back to copy-then-delete.
    /// `RENAME_EXCL` also closes the collision-plan race: if anything appears
    /// at the target (including a rollback source), both files stay intact.
    /// A changed mount fails with `EXDEV`.
    static func atomicExclusiveRename(
        from source: URL,
        to destination: URL
    ) throws {
        try DurableFileIO.atomicExclusiveRename(
            from: source,
            to: destination
        )
    }

    /// `DSC_0001.NEF` → `DSC_0001 (1).NEF` when the name is already taken.
    static func collisionFreeURL(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var counter = 0
        while true {
            let candidateName = suffixedFilename(filename, suffix: counter)
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private static func suffixedFilename(_ filename: String, suffix: Int) -> String {
        guard suffix > 0 else { return filename }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
    }

    /// A conservative case-fold prevents in-batch collisions on normal
    /// case-insensitive macOS volumes. On a case-sensitive destination this
    /// may choose an unnecessary suffix, but never an unsafe duplicate.
    private static func normalizedReservationName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
