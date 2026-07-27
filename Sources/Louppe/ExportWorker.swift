import Foundation

/// Filesystem-only Export implementation, CleanUpWorker's shape: it owns no
/// UI state and creates a fresh FileManager inside each call. Copy duplicates
/// files and never touches originals. Copy and Move both reserve one shared
/// collision suffix per photo, so RAW+JPEG partners keep matching basenames.
/// A partial pair failure is rolled back; the result reports if rollback
/// itself also failed.
enum ExportWorker {
    typealias Progress = CleanUpWorker.Progress

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
        /// An active journal remains and must restore the conservative
        /// pre-export state before another file operation starts.
        let requiresRecovery: Bool
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
    }

    struct PlannedFile: Sendable, Equatable {
        let source: URL
        let target: URL
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
    static func makePlan(for items: [PhotoItem], in destination: URL) -> Plan {
        let fm = FileManager.default
        var reservedPaths: Set<String> = []
        var plannedItems: [PlannedItem] = []
        plannedItems.reserveCapacity(items.count)

        for item in items {
            let sources = item.allURLs
            var suffix = 0
            while true {
                let targets = sources.map {
                    destination.appendingPathComponent(
                        suffixedFilename($0.lastPathComponent, suffix: suffix))
                }
                let normalizedPaths = targets.map { normalizedReservationPath($0) }
                let targetsAreDistinct = Set(normalizedPaths).count == normalizedPaths.count
                let areAvailable = targetsAreDistinct && zip(targets, normalizedPaths).allSatisfy {
                    !fm.fileExists(atPath: $0.0.path) && !reservedPaths.contains($0.1)
                }
                if areAvailable {
                    reservedPaths.formUnion(normalizedPaths)
                    plannedItems.append(PlannedItem(
                        itemID: item.id,
                        files: zip(sources, targets).map {
                            PlannedFile(source: $0.0, target: $0.1)
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
        progress: @escaping Progress
    ) -> CopyResult {
        let fm = FileManager()
        let plan = makePlan(for: items, in: destination)
        let writer: FileOperationJournal.Writer
        do {
            writer = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: plan.items.flatMap { item in
                    item.files.map {
                        FileOperationJournal.Seed(
                            itemID: item.itemID,
                            source: $0.source,
                            destination: $0.target
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
                requiresRecovery: false
            )
        }
        var reporter = ThrottledProgress(total: plan.totalFiles, callback: progress)
        var copied = 0
        var failedPhotos = 0
        var inconsistentPhotos = 0
        var cancelled = false
        var journalFailure = false
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
                    location: .none
                )
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
                    do {
                        try fm.copyItem(at: file.source, to: temporary)
                        touched.location = .temporary(temporary)
                    } catch {
                        failed = true
                    }
                }
                if !failed {
                    do {
                        try writer.mark(
                            .staged,
                            fileAt: fileIndex,
                            identityAt: temporary
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                    }
                }
                if !failed {
                    do {
                        try fm.moveItem(at: temporary, to: file.target)
                        touched.location = .destination
                    } catch {
                        failed = true
                    }
                }
                if !failed {
                    do {
                        try writer.mark(
                            .completed,
                            fileAt: fileIndex,
                            identityAt: file.target
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
                var rollbackFailed = false
                for touched in touchedForItem.reversed() {
                    if !rollbackCopy(touched, fileManager: fm) {
                        rollbackFailed = true
                    } else if (try? writer.mark(.rolledBack, fileAt: touched.index)) == nil {
                        journalFailure = true
                    }
                }
                if !cancelled { failedPhotos += 1 }
                if rollbackFailed { inconsistentPhotos += 1 }
                if cancelled { break }
                if journalFailure {
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
        }
        return CopyResult(
            copiedFiles: copied,
            failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos,
            cancelled: cancelled,
            journalFailure: journalFailure,
            requiresRecovery: inconsistentPhotos > 0 || !journalFinalized
        )
    }

    static func move(
        _ items: [PhotoItem],
        to destination: URL,
        journalDirectory: URL? = nil,
        progress: @escaping Progress
    ) -> MoveResult {
        let fm = FileManager()
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let plan = makePlan(for: items, in: destination)
        let writer: FileOperationJournal.Writer
        do {
            writer = try FileOperationJournal.start(
                kind: .exportMove,
                seeds: plan.items.flatMap { item in
                    item.files.map {
                        FileOperationJournal.Seed(
                            itemID: item.itemID,
                            source: $0.source,
                            destination: $0.target
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
                requiresRecovery: false
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
                    location: .none
                )
                // "Moving" a file into the folder it already lives in would
                // only rename the original with a collision suffix.
                if file.source.deletingLastPathComponent()
                    .resolvingSymlinksInPath().standardizedFileURL.path == destinationPath {
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
                    do {
                        try fm.moveItem(at: file.source, to: temporary)
                        touched.location = .temporary(temporary)
                    } catch {
                        failed = true
                    }
                }
                if !failed {
                    do {
                        try writer.mark(
                            .staged,
                            fileAt: fileIndex,
                            identityAt: temporary
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                    }
                }
                if !failed {
                    do {
                        try fm.moveItem(at: temporary, to: file.target)
                        touched.location = .destination
                    } catch {
                        failed = true
                    }
                }
                if !failed {
                    do {
                        try writer.mark(
                            .completed,
                            fileAt: fileIndex,
                            identityAt: file.target
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
                    } else if (try? writer.mark(.rolledBack, fileAt: touched.index)) == nil {
                        journalFailure = true
                    }
                }
                failedPhotos += 1
                if rollbackFailed { inconsistentPhotos += 1 }
                if journalFailure {
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
            requiresRecovery: inconsistentPhotos > 0 || !journalFinalized
        )
    }

    private enum ExportFileLocation {
        case none
        case temporary(URL)
        case destination
    }

    private struct TouchedExportFile {
        let file: PlannedFile
        let index: Int
        var location: ExportFileLocation
    }

    private static func rollbackCopy(
        _ touched: TouchedExportFile,
        fileManager: FileManager
    ) -> Bool {
        do {
            switch touched.location {
            case .none:
                break
            case .temporary(let url):
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            case .destination:
                if fileManager.fileExists(atPath: touched.file.target.path) {
                    try fileManager.removeItem(at: touched.file.target)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private static func rollbackMove(
        _ touched: TouchedExportFile,
        fileManager: FileManager
    ) -> Bool {
        do {
            let movedURL: URL?
            switch touched.location {
            case .none:
                movedURL = nil
            case .temporary(let url):
                movedURL = url
            case .destination:
                movedURL = touched.file.target
            }
            if let movedURL, fileManager.fileExists(atPath: movedURL.path) {
                guard !fileManager.fileExists(atPath: touched.file.source.path) else {
                    return false
                }
                try fileManager.moveItem(at: movedURL, to: touched.file.source)
            }
            return true
        } catch {
            return false
        }
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
    private static func normalizedReservationPath(_ url: URL) -> String {
        url.standardizedFileURL.path.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
