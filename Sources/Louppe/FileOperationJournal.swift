import CryptoKit
import Darwin
import Foundation

/// Persistent process-crash checkpoints for every filesystem operation that
/// can leave a RAW+JPEG pair split if the process dies between members.
///
/// Each operation owns a directory containing one immutable plan and tiny
/// per-file state files. Updating file 9,000 therefore rewrites one small JSON
/// file, not a 9,000-entry journal. The directory becomes visible to recovery
/// only after the complete plan is atomically renamed into place.
enum FileOperationJournal {
    enum Kind: String, Codable, Sendable {
        case exportCopy
        case exportMove
        case moveToTrash
        case restoreFromTrash
    }

    enum StepState: String, Codable, Sendable {
        case started
        case staged
        case completed
        case rolledBack
    }

    struct Seed: Sendable {
        let itemID: String
        let source: URL
        let destination: URL?
        /// Identity captured when this physical file entered the session.
        /// Low-level recovery fixtures may omit it, but app workers always
        /// carry it so operation activation cannot silently adopt a later
        /// same-path replacement.
        let expectedIdentity: FileIdentity?
        /// The file whose stable volume/inode identity should be captured.
        /// Trash restore moves from `destination` back to `source`, so its
        /// identity URL differs from the desired source-state URL.
        let identityURL: URL

        init(
            itemID: String,
            source: URL,
            destination: URL?,
            expectedIdentity: FileIdentity? = nil,
            identityURL: URL? = nil
        ) {
            self.itemID = itemID
            self.source = source
            self.destination = destination
            self.expectedIdentity = expectedIdentity
            self.identityURL = identityURL ?? source
        }
    }

    struct Token: Codable, Equatable, Sendable {
        let operationID: String
        let directory: URL
    }

    struct FileIdentity: Codable, Equatable, Sendable {
        struct Timestamp: Codable, Equatable, Sendable {
            let seconds: Int64
            let nanoseconds: Int64
        }

        let volumeRootPath: String
        /// Stable volume UUID when the filesystem exposes one. Older journals
        /// omit it and continue to use the mount-root path conservatively.
        let volumeUUIDString: String?
        let systemNumber: UInt64
        let fileNumber: UInt64
        /// Optional for compatibility with journals written before these
        /// content/change guards were added.
        let logicalSize: Int64?
        let modificationTime: Timestamp?
        let statusChangeTime: Timestamp?
        let birthTime: Timestamp?
    }

    struct PlannedFile: Codable, Equatable, Sendable {
        let itemID: String
        let sourcePath: String
        let destinationPath: String?
        let temporaryPath: String?
        let identity: FileIdentity

        /// Version-3 plans bind every pathname to the exact bytes passed to
        /// the filesystem. `String`-backed file URLs can normalize canonically
        /// equivalent Unicode spellings (and cannot represent arbitrary invalid
        /// UTF-8), so the human-readable paths above are never recovery
        /// authority for a new plan. These fields remain optional solely so
        /// installed version-1/2 journals can still be decoded conservatively.
        let sourcePathBytes: Data?
        let destinationPathBytes: Data?
        let temporaryPathBytes: Data?

        init(
            itemID: String,
            sourcePath: String,
            destinationPath: String?,
            temporaryPath: String?,
            identity: FileIdentity,
            sourcePathBytes: Data? = nil,
            destinationPathBytes: Data? = nil,
            temporaryPathBytes: Data? = nil
        ) {
            self.itemID = itemID
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.temporaryPath = temporaryPath
            self.identity = identity
            self.sourcePathBytes = sourcePathBytes
            self.destinationPathBytes = destinationPathBytes
            self.temporaryPathBytes = temporaryPathBytes
        }
    }

    struct Plan: Codable, Equatable, Sendable {
        let version: Int
        let operationID: String
        let kind: Kind
        let createdAt: Date
        let files: [PlannedFile]
    }

    struct StateRecord: Codable, Equatable, Sendable {
        let state: StepState
        /// `trashItem` chooses this path only after moving the file.
        let resolvedDestinationPath: String?
        /// Exact filesystem representation for a resolved destination written
        /// by a version-3 writer. Legacy state records omit it.
        let resolvedDestinationPathBytes: Data?
        /// Identity of the staged/completed file at the time this checkpoint
        /// was written. Recovery refuses to touch a same-named replacement.
        let resolvedIdentity: FileIdentity?
        let updatedAt: Date

        init(
            state: StepState,
            resolvedDestinationPath: String?,
            resolvedDestinationPathBytes: Data? = nil,
            resolvedIdentity: FileIdentity?,
            updatedAt: Date
        ) {
            self.state = state
            self.resolvedDestinationPath = resolvedDestinationPath
            self.resolvedDestinationPathBytes =
                resolvedDestinationPathBytes
            self.resolvedIdentity = resolvedIdentity
            self.updatedAt = updatedAt
        }
    }

    private struct CommitRecord: Codable {
        let version: Int
        let operationID: String
        let planDigest: String
    }

    private enum ManipulatedPathRole {
        case source
        case owned
    }

    private enum PlannedPathRole {
        case source
        case destination
        case temporary
    }

    final class Writer {
        let token: Token
        let plan: Plan
        private let stepsDirectory: URL
        private var operationLock: OperationLock?

        fileprivate init(
            token: Token,
            plan: Plan,
            operationLock: OperationLock
        ) {
            self.token = token
            self.plan = plan
            self.operationLock = operationLock
            stepsDirectory = token.directory.appendingPathComponent(
                "steps",
                isDirectory: true
            )
        }

        func temporaryURL(at index: Int) -> URL? {
            guard plan.files.indices.contains(index) else { return nil }
            return try? FileOperationJournal.plannedURL(
                for: plan.files[index],
                role: .temporary,
                planVersion: plan.version
            )
        }

        /// Revalidates the source captured in the immutable plan immediately
        /// before a Move rename. A same-named replacement or in-place rewrite
        /// must never become the file Louppe moves.
        func requireUnchangedSource(at index: Int) throws {
            guard plan.files.indices.contains(index) else {
                throw JournalError.invalidFileIndex
            }
            let file = plan.files[index]
            try FileOperationJournal.requireIdentity(
                file.identity,
                at: FileOperationJournal.plannedURL(
                    for: file,
                    role: .source,
                    planVersion: plan.version
                ),
                includeStatusChange: true
            )
        }

        func requirePlannedIdentity(
            at index: Int,
            fileURL: URL,
            includeStatusChange: Bool = false
        ) throws {
            guard plan.files.indices.contains(index) else {
                throw JournalError.invalidFileIndex
            }
            try FileOperationJournal.requireIdentity(
                plan.files[index].identity,
                at: fileURL,
                includeStatusChange: includeStatusChange
            )
        }

        func plannedIdentity(at index: Int) throws -> FileIdentity {
            guard plan.files.indices.contains(index) else {
                throw JournalError.invalidFileIndex
            }
            return plan.files[index].identity
        }

        func mark(
            _ state: StepState,
            fileAt index: Int,
            resolvedDestination: URL? = nil,
            identityAt identityURL: URL? = nil,
            expectedIdentity: FileIdentity? = nil,
            includeStatusChange: Bool = true
        ) throws {
            guard plan.files.indices.contains(index) else {
                throw JournalError.invalidFileIndex
            }
            let resolvedIdentity: FileIdentity?
            if let identityURL {
                let current = try FileOperationJournal.fileIdentity(
                    at: identityURL
                )
                if let expectedIdentity,
                   !FileOperationJournal.identitiesMatch(
                    expected: expectedIdentity,
                    actual: current,
                    includeStatusChange: includeStatusChange
                   ) {
                    // Do not let a pathname replacement become operation-owned
                    // merely because it raced into place between a worker's
                    // validation and this durable checkpoint.
                    throw JournalError.sourceChangedSinceScan(identityURL)
                }
                resolvedIdentity = current
            } else {
                resolvedIdentity = nil
            }
            let resolvedPathBytes = try resolvedDestination.map {
                try FileOperationJournal.validatedPathBytes(for: $0)
            }
            let resolvedPath = try resolvedPathBytes.map {
                try FileOperationJournal.exactURL(
                    fromFileSystemPathBytes: $0
                ).path
            }
            let record = StateRecord(
                state: state,
                resolvedDestinationPath: resolvedPath,
                resolvedDestinationPathBytes: resolvedPathBytes,
                resolvedIdentity: resolvedIdentity,
                updatedAt: Date()
            )
            try DurableFileIO.atomicWrite(
                Self.encoder.encode(record),
                to: stateURL(at: index),
                // `started` authorizes the first filesystem mutation and
                // `staged` authorizes a temporary-to-final rename. Fully flush
                // those boundaries so a durable media move can never outrun
                // the checkpoint needed to recover it after power loss. Final
                // and rolled-back records are covered by the final commit's
                // full flush and remain safely idempotent if lost mid-batch.
                fullSync: state == .started || state == .staged
            )
        }

        /// A committed marker means the worker completed and its coordinator
        /// may safely keep the resulting filesystem state. If the process dies
        /// before the journal directory is removed, launch recovery only
        /// removes the stale journal instead of undoing a completed operation.
        func markCommitted() throws {
            let record = CommitRecord(
                version: 1,
                operationID: plan.operationID,
                planDigest: try FileOperationJournal.planDigest(
                    at: token.directory.appendingPathComponent("plan.json")
                )
            )
            try DurableFileIO.atomicWrite(
                FileOperationJournal.encoder.encode(record),
                to: token.directory.appendingPathComponent("committed"),
                fullSync: true
            )
        }

        fileprivate func releaseOperationLock() {
            operationLock?.release()
            operationLock = nil
        }

#if LOUPPE_TESTING
        /// Models process death: the OS releases the advisory lock while the
        /// persistent journal and filesystem state survive for launch recovery.
        func relinquishOperationLockForCrashSimulation() {
            releaseOperationLock()
        }
#endif

        private func stateURL(at index: Int) -> URL {
            stepsDirectory.appendingPathComponent(
                String(format: "%08d.json", index)
            )
        }

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }()
    }

    struct RecoveryReport: Equatable, Sendable {
        var discoveredOperations = 0
        var restoredOperations = 0
        var committedOperations = 0
        var unresolvedOperations = 0
        var restoredFiles = 0
        var preservedCopies = 0
        var removedPartialCopies = 0
        var unresolvedFiles = 0
        var operationLockUnavailable = false
        var unavailableVolumes: [String] = []
        var details: [String] = []

        var foundOperations: Int { discoveredOperations }

        var hasUnresolvedFiles: Bool { unresolvedFiles > 0 }
    }

    enum JournalError: LocalizedError {
        case invalidFileIndex
        case invalidFileSystemPath
        case missingFileIdentity(URL)
        case sourceChangedSinceScan(URL)
        case unsafePlan(URL)
        case corruptPlan(URL)
        case operationInUse
        case recoveryRequired
        case cannotInspectOperations(URL)
        case cannotLockOperations(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidFileIndex:
                return "The operation journal contains an invalid file index."
            case .invalidFileSystemPath:
                return "Louppe refused a filename whose exact filesystem representation could not be preserved safely."
            case .missingFileIdentity(let url):
                return "Louppe couldn't identify \(url.lastPathComponent) before starting the file operation."
            case .sourceChangedSinceScan(let url):
                return "\(url.lastPathComponent) changed after it was scanned. Rescan the folder before changing files."
            case .unsafePlan:
                return "Louppe refused an unsafe file-operation plan before changing any files."
            case .corruptPlan:
                return "An interrupted-operation journal is unreadable."
            case .operationInUse:
                return "Another Louppe process is currently changing files."
            case .recoveryRequired:
                return "An interrupted file operation must be recovered before another one can start."
            case .cannotInspectOperations:
                return "Louppe couldn't verify that its operation journal is clear."
            case .cannotLockOperations(let code):
                return "Louppe couldn't lock its operation journal (system error \(code))."
            }
        }
    }

    static func start(
        kind: Kind,
        seeds: [Seed],
        directory rootOverride: URL? = nil
    ) throws -> Writer {
        let fm = FileManager()
        let root = rootOverride ?? defaultDirectory
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let operationLock = try OperationLock.acquire(in: root)
        cleanupRetiredOperations(in: root)
        guard try pendingOperationURLs(
            in: root,
            fileManager: fm
        ).isEmpty else {
            throw JournalError.recoveryRequired
        }

        let operationID = UUID().uuidString.lowercased()
        let creating = root.appendingPathComponent(
            "\(operationID).creating",
            isDirectory: true
        )
        let active = root.appendingPathComponent(
            "\(operationID).operation",
            isDirectory: true
        )
        try fm.createDirectory(
            at: creating.appendingPathComponent("steps", isDirectory: true),
            withIntermediateDirectories: true
        )

        do {
            let files = try seeds.enumerated().map { index, seed in
                let destination = seed.destination
                let temporary: URL?
                switch kind {
                case .exportCopy, .exportMove:
                    guard let destination else {
                        throw JournalError.unsafePlan(creating)
                    }
                    temporary = try temporaryURL(
                        beside: destination,
                        operationID: operationID,
                        fileIndex: index
                    )
                case .moveToTrash, .restoreFromTrash:
                    temporary = nil
                }
                let currentIdentity = try fileIdentity(at: seed.identityURL)
                if kind != .exportCopy,
                   try linkCount(at: seed.identityURL) != 1 {
                    // A directory entry with another hard link cannot be
                    // located unambiguously after a pre-checkpoint Trash or
                    // Move crash. Copy is non-mutating and remains safe.
                    throw JournalError.unsafePlan(creating)
                }
                if let expectedIdentity = seed.expectedIdentity,
                   !identitiesMatch(
                    expected: expectedIdentity,
                    actual: currentIdentity,
                    includeStatusChange: true
                   ) {
                    throw JournalError.sourceChangedSinceScan(seed.identityURL)
                }
                let sourcePathBytes = try validatedPathBytes(
                    for: seed.source
                )
                let destinationPathBytes = try destination.map {
                    try validatedPathBytes(for: $0)
                }
                let temporaryPathBytes = try temporary.map {
                    try validatedPathBytes(for: $0)
                }
                return PlannedFile(
                    itemID: seed.itemID,
                    sourcePath: seed.source.path,
                    destinationPath: destination?.path,
                    temporaryPath: temporary?.path,
                    identity: seed.expectedIdentity ?? currentIdentity,
                    sourcePathBytes: sourcePathBytes,
                    destinationPathBytes: destinationPathBytes,
                    temporaryPathBytes: temporaryPathBytes
                )
            }
            let plan = Plan(
                version: 3,
                operationID: operationID,
                kind: kind,
                createdAt: Date(),
                files: files
            )
            do {
                try validatePlan(plan, at: creating)
            } catch {
                throw JournalError.unsafePlan(creating)
            }
            let encodedPlan = try encoder.encode(plan)
            guard encodedPlan.count <= maximumPlanBytes else {
                throw JournalError.unsafePlan(creating)
            }
            try DurableFileIO.atomicWrite(
                encodedPlan,
                to: creating.appendingPathComponent("plan.json"),
                fullSync: true
            )
            // The completed plan becomes discoverable in one rename.
            try fm.moveItem(at: creating, to: active)
            try DurableFileIO.syncRenameDirectories(
                from: creating,
                to: active,
                fullSync: true
            )
            return Writer(
                token: Token(operationID: operationID, directory: active),
                plan: plan,
                operationLock: operationLock
            )
        } catch {
            if fm.fileExists(atPath: active.path) {
                // The immutable plan became discoverable but its parent flush
                // did not complete. Keep the journal and force recovery;
                // reporting an ordinary preflight failure would allow a
                // second operation to start over active evidence.
                throw JournalError.recoveryRequired
            }
            try? fm.removeItem(at: creating)
            throw error
        }
    }

    static func remove(_ token: Token) throws {
        try retireActiveOperation(token)
    }

    /// Removes an operation from the active recovery namespace in one rename.
    /// Recursive deletion happens only after the parent directory has durably
    /// recorded the `.retired` name, so a crash can never leave an active
    /// journal with its plan or commit marker partially dismantled.
    private static func retireActiveOperation(_ token: Token) throws {
        let active = token.directory.standardizedFileURL
        guard UUID(uuidString: token.operationID) != nil,
              token.operationID == token.operationID.lowercased(),
              active.lastPathComponent == "\(token.operationID).operation" else {
            throw JournalError.corruptPlan(active)
        }
        let root = active.deletingLastPathComponent()
        let retired = root.appendingPathComponent(
            "\(token.operationID)-\(UUID().uuidString.lowercased()).retired",
            isDirectory: true
        )
        try DurableFileIO.atomicExclusiveRename(
            from: active,
            to: retired
        )
        try DurableFileIO.syncRenameDirectories(
            from: active,
            to: retired,
            fullSync: true
        )
        cleanupRetiredOperation(at: retired)
    }

    private static func cleanupRetiredOperations(in root: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where isRetiredOperationURL(url) {
            cleanupRetiredOperation(at: url)
        }
    }

    private static func cleanupRetiredOperation(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            try? DurableFileIO.syncRemoval(of: url, fullSync: false)
        } catch {
            // The durable `.retired` rename is the correctness boundary.
            // Cleanup is intentionally retryable and never makes an operation
            // active again.
        }
    }

    /// Seals an operation whose filesystem state is consistent. A committed
    /// marker makes a later stale journal harmless. If that marker cannot be
    /// written, the active journal must remain retryable: removing it would
    /// discard the only durable evidence needed to reconcile the operation.
    @discardableResult
    static func finalize(
        _ writer: Writer,
        operationIsConsistent: Bool
    ) -> Bool {
        defer { writer.releaseOperationLock() }
        guard operationIsConsistent else { return true }
        do {
            try writer.markCommitted()
            // A committed journal is safe even if cleanup fails. Recovery
            // preserves the operation's result and removes only the journal.
            try? remove(writer.token)
            return true
        } catch {
            return false
        }
    }

    static func hasPendingOperations(directory rootOverride: URL? = nil) -> Bool {
        let root = rootOverride ?? defaultDirectory
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return false }
        do {
            return try !pendingOperationURLs(
                in: root,
                fileManager: fm
            ).isEmpty
        } catch {
            // This flag gates launch and new file operations. Uncertainty must
            // start visible recovery, never silently mean "no journal."
            return true
        }
    }

    static func errorRequiresRecovery(_ error: Error) -> Bool {
        guard let journalError = error as? JournalError else { return false }
        switch journalError {
        case .operationInUse,
             .recoveryRequired,
             .cannotInspectOperations,
             .cannotLockOperations,
             .corruptPlan:
            return true
        case .invalidFileIndex,
             .invalidFileSystemPath,
             .missingFileIdentity,
             .sourceChangedSinceScan,
             .unsafePlan:
            return false
        }
    }

    /// Reconciles every *active* operation without overwriting an existing
    /// path. Mutating operations restore their conservative source state;
    /// Copy keeps every identity-verified staged or completed destination.
    static func recoverPendingOperations(
        directory rootOverride: URL? = nil
    ) -> RecoveryReport {
        let root = rootOverride ?? defaultDirectory
        let fm = FileManager()
        var report = RecoveryReport()
        guard fm.fileExists(atPath: root.path) else { return report }
        let operationLock: OperationLock
        do {
            operationLock = try OperationLock.acquire(in: root)
        } catch {
            if case JournalError.operationInUse = error {
                report.operationLockUnavailable = true
            }
            report.unresolvedOperations = 1
            report.unresolvedFiles = 1
            report.details.append(error.localizedDescription)
            return report
        }
        defer { operationLock.release() }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
        } catch {
            report.unresolvedOperations = 1
            report.unresolvedFiles = 1
            report.details.append(
                JournalError.cannotInspectOperations(root)
                    .localizedDescription
            )
            return report
        }

        // A .creating directory was never activated, so no corresponding file
        // operation was allowed to start.
        for url in contents where isCreatingOperationURL(url) {
            try? fm.removeItem(at: url)
        }
        for url in contents where isRetiredOperationURL(url) {
            cleanupRetiredOperation(at: url)
        }

        for operationURL in contents
            .filter({ $0.pathExtension == "operation" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            report.discoveredOperations += 1
            do {
                let plan = try decodePlan(at: operationURL)
                let committedURL = operationURL
                    .appendingPathComponent("committed")
                if fm.fileExists(atPath: committedURL.path) {
                    try validateCommit(at: committedURL, for: plan)
                    try retireActiveOperation(Token(
                        operationID: plan.operationID,
                        directory: operationURL
                    ))
                    report.committedOperations += 1
                    continue
                }

                var operationUnresolved = 0
                for index in plan.files.indices {
                    let state = readState(
                        at: operationURL,
                        index: index
                    )
                    do {
                        let result = try recover(
                            plan.files[index],
                            kind: plan.kind,
                            state: state,
                            operationID: plan.operationID,
                            fileIndex: index,
                            planVersion: plan.version
                        )
                        report.restoredFiles += result.restoredFiles
                        report.preservedCopies += result.preservedCopies
                        report.removedPartialCopies += result.removedCopies
                    } catch {
                        operationUnresolved += 1
                        report.details.append(error.localizedDescription)
                        let volume = plan.files[index].identity.volumeRootPath
                        if !fm.fileExists(atPath: volume),
                           !report.unavailableVolumes.contains(volume) {
                            report.unavailableVolumes.append(volume)
                        }
                    }
                }

                if operationUnresolved == 0 {
                    try retireActiveOperation(Token(
                        operationID: plan.operationID,
                        directory: operationURL
                    ))
                    report.restoredOperations += 1
                } else {
                    report.unresolvedOperations += 1
                    report.unresolvedFiles += operationUnresolved
                }
            } catch {
                report.unresolvedOperations += 1
                report.unresolvedFiles += 1
                report.details.append(error.localizedDescription)
            }
        }
        return report
    }

    private struct RecoveredFileCounts {
        var restoredFiles = 0
        var preservedCopies = 0
        var removedCopies = 0
    }

    private static func recover(
        _ file: PlannedFile,
        kind: Kind,
        state: StateRecord?,
        operationID: String,
        fileIndex: Int,
        planVersion: Int
    ) throws -> RecoveredFileCounts {
        switch kind {
        case .exportCopy:
            return try recoverCopy(
                file,
                state: state,
                operationID: operationID,
                fileIndex: fileIndex,
                planVersion: planVersion
            )
        case .exportMove:
            return try recoverMove(
                file,
                state: state,
                operationID: operationID,
                fileIndex: fileIndex,
                planVersion: planVersion
            )
        case .moveToTrash:
            return try recoverTrash(
                file,
                state: state,
                planVersion: planVersion
            )
        case .restoreFromTrash:
            return try recoverTrashRestore(
                file,
                planVersion: planVersion
            )
        }
    }

    private static func recoverCopy(
        _ file: PlannedFile,
        state: StateRecord?,
        operationID: String,
        fileIndex: Int,
        planVersion: Int
    ) throws -> RecoveredFileCounts {
        let source = try plannedURL(
            for: file,
            role: .source,
            planVersion: planVersion
        )
        guard file.temporaryPath != nil,
              file.destinationPath != nil else {
            throw RecoveryError.unverifiedOwnedFile(source)
        }
        let temporary = try plannedURL(
            for: file,
            role: .temporary,
            planVersion: planVersion
        )
        let destination = try plannedURL(
            for: file,
            role: .destination,
            planVersion: planVersion
        )
        var existingCopies: [URL] = []
        try validateTemporary(
            temporary,
            for: file,
            operationID: operationID,
            fileIndex: fileIndex,
            planVersion: planVersion
        )
        if pathEntryExists(temporary) {
            existingCopies.append(temporary)
        }
        if pathEntryExists(destination) {
            existingCopies.append(destination)
        }

        guard existingCopies.count <= 1 else {
            throw RecoveryError.multipleRecoveryCandidates(source)
        }
        guard let copy = existingCopies.first else {
            return RecoveredFileCounts()
        }
        let currentCopyIdentity = try fileIdentity(at: copy)
        if state?.state == .started {
            if let recordedIdentity = state?.resolvedIdentity {
                guard identitiesMatch(
                    expected: recordedIdentity,
                    actual: currentCopyIdentity,
                    includeStatusChange: false
                ) else {
                    throw RecoveryError.unverifiedOwnedFile(copy)
                }
                // A failed copy call can still have written the entire file.
                // Keep it only when the exact planned original is available
                // and a race-safe byte comparison proves completion.
                if !completedCopyMatchesSource(
                    plannedSourceIdentity: file.identity,
                    source: source,
                    copy: copy,
                    copyIdentity: currentCopyIdentity
                ) {
                    return try removeRecordedPartialCopy(
                        copy,
                        temporary: temporary,
                        destination: destination,
                        identity: currentCopyIdentity
                    )
                }
            } else {
                // Legacy/current journals may have died after copyItem
                // returned but before the staged identity was checkpointed.
                // The operation-specific path alone is not ownership proof;
                // the unchanged planned original plus two identity checks and
                // a full byte comparison are.
                guard exactPathsEqual(copy, temporary),
                      completedCopyMatchesSource(
                        plannedSourceIdentity: file.identity,
                        source: source,
                        copy: copy,
                        copyIdentity: currentCopyIdentity
                      ) else {
                    throw RecoveryError.unverifiedOwnedFile(copy)
                }
            }
        } else {
            // A staged checkpoint is written only after copyItem returned, the
            // duplicate was fully flushed, and the source still matched the
            // scan. Copy never mutates the original, so losing or ejecting
            // that source afterward is not a reason to destroy a successfully
            // copied file. The resolved identity—not the temporary filename—
            // is the proof used to finish an interrupted final rename.
            guard state?.state == .staged || state?.state == .completed,
                  let identity = state?.resolvedIdentity,
                  identitiesMatch(
                    expected: identity,
                    actual: currentCopyIdentity,
                    includeStatusChange: false
                  ) else {
                throw RecoveryError.unverifiedOwnedFile(copy)
            }
        }
        try requireIdentity(
            currentCopyIdentity,
            at: copy,
            includeStatusChange: false
        )

        let finalCopy: URL
        if exactPathsEqual(copy, temporary) {
            // The staged file itself was already flushed before the checkpoint.
            // Flush it again before publishing its final name so recovery stays
            // correct even for a legacy journal whose previous recovery was
            // interrupted while moving a completed copy back to temporary.
            try DurableFileIO.syncFile(at: temporary, fullSync: true)
            try DurableFileIO.atomicExclusiveRename(
                from: temporary,
                to: destination
            )
            try DurableFileIO.syncRenameDirectories(
                from: temporary,
                to: destination,
                fullSync: true
            )
            finalCopy = destination
        } else {
            if state?.state == .staged {
                // The rename may have completed just before a directory flush
                // or final checkpoint failed. Re-establish both durability
                // boundaries without consulting the now-optional source drive.
                try DurableFileIO.syncFile(at: destination, fullSync: true)
                try DurableFileIO.syncDirectory(
                    destination.deletingLastPathComponent(),
                    fullSync: true
                )
            }
            finalCopy = destination
        }

        let finalIdentity = try fileIdentity(at: finalCopy)
        guard identitiesMatch(
            expected: currentCopyIdentity,
            actual: finalIdentity,
            includeStatusChange: false
        ) else {
            throw RecoveryError.unverifiedOwnedFile(finalCopy)
        }
        var counts = RecoveredFileCounts()
        counts.preservedCopies = 1
        return counts
    }

    private static func completedCopyMatchesSource(
        plannedSourceIdentity: FileIdentity,
        source: URL,
        copy: URL,
        copyIdentity: FileIdentity
    ) -> Bool {
        do {
            try requireIdentity(
                plannedSourceIdentity,
                at: source,
                includeStatusChange: true
            )
            guard contentsEqual(source, copy) else { return false }
            // Repeat both identity checks after the potentially long read so
            // neither a source nor temporary-path replacement can be accepted.
            try requireIdentity(
                plannedSourceIdentity,
                at: source,
                includeStatusChange: true
            )
            try requireIdentity(
                copyIdentity,
                at: copy,
                includeStatusChange: false
            )
            return true
        } catch {
            return false
        }
    }

    /// Deletes only a partial inode recorded by the `.started` checkpoint.
    /// Moving it exclusively to the operation's other reserved path before
    /// unlinking prevents a late pathname replacement from being removed.
    private static func removeRecordedPartialCopy(
        _ copy: URL,
        temporary: URL,
        destination: URL,
        identity: FileIdentity
    ) throws -> RecoveredFileCounts {
        let quarantine = exactPathsEqual(copy, temporary)
            ? destination
            : temporary
        guard !pathEntryExists(quarantine) else {
            throw RecoveryError.multipleRecoveryCandidates(copy)
        }
        try requireIdentity(
            identity,
            at: copy,
            includeStatusChange: false
        )
        try DurableFileIO.atomicExclusiveRename(
            from: copy,
            to: quarantine
        )
        try DurableFileIO.syncRenameDirectories(
            from: copy,
            to: quarantine,
            fullSync: true
        )
        let quarantinedIdentity = try fileIdentity(at: quarantine)
        guard identitiesMatch(
            expected: identity,
            actual: quarantinedIdentity,
            includeStatusChange: false
        ) else {
            throw RecoveryError.unverifiedOwnedFile(quarantine)
        }
        try requireIdentity(
            quarantinedIdentity,
            at: quarantine,
            includeStatusChange: false
        )
        try DurableFileIO.unlinkRegularFile(at: quarantine)
        try DurableFileIO.syncRemoval(of: quarantine, fullSync: true)
        guard !pathEntryExists(copy), !pathEntryExists(quarantine) else {
            throw RecoveryError.unverifiedOwnedFile(quarantine)
        }
        var counts = RecoveredFileCounts()
        counts.removedCopies = 1
        return counts
    }

    private static func recoverMove(
        _ file: PlannedFile,
        state: StateRecord?,
        operationID: String,
        fileIndex: Int,
        planVersion: Int
    ) throws -> RecoveredFileCounts {
        let source = try plannedURL(
            for: file,
            role: .source,
            planVersion: planVersion
        )
        let temporary = file.temporaryPath == nil
            ? nil
            : try plannedURL(
                for: file,
                role: .temporary,
                planVersion: planVersion
            )
        if let temporary {
            try validateTemporary(
                temporary,
                for: file,
                operationID: operationID,
                fileIndex: fileIndex,
                planVersion: planVersion
            )
        }
        let destination = file.destinationPath == nil
            ? nil
            : try plannedURL(
                for: file,
                role: .destination,
                planVersion: planVersion
            )
        let sourceExists = pathEntryExists(source)
        let temporaryExists = temporary.map(pathEntryExists) ?? false
        let destinationExists = destination.map(pathEntryExists) ?? false

        var existingLocations: [(url: URL, isTemporary: Bool)] = []
        if temporaryExists, let temporary {
            existingLocations.append((temporary, true))
        }
        if destinationExists, let destination {
            existingLocations.append((destination, false))
        }
        guard existingLocations.count <= 1 else {
            throw RecoveryError.multipleRecoveryCandidates(source)
        }

        if sourceExists {
            // A same-named replacement is not proof that the move rolled back.
            // Validate the planned original before deleting anything elsewhere.
            // Ignore ctime here because a successful rollback changes it.
            // Stable inode/birth/size/mtime still prove ownership; if a second
            // location exists, a byte comparison below proves content too.
            let restoredSourceIdentity = try fileIdentity(at: source)
            guard identitiesMatch(
                expected: file.identity,
                actual: restoredSourceIdentity,
                includeStatusChange: false
            ) else {
                throw RecoveryError.unverifiedOwnedFile(source)
            }
            if let location = existingLocations.first {
                let identity = try movedArtifactIdentity(
                    file,
                    state: state,
                    at: location.url,
                    isTemporary: location.isTemporary
                )
                let currentArtifactIdentity = try fileIdentity(
                    at: location.url
                )
                guard identitiesMatch(
                    expected: identity,
                    actual: currentArtifactIdentity,
                    includeStatusChange: false
                ) else {
                    throw RecoveryError.unverifiedOwnedFile(location.url)
                }
                guard contentsEqual(source, location.url) else {
                    throw RecoveryError.contentMismatch(
                        source,
                        location.url
                    )
                }
                try requireIdentity(
                    restoredSourceIdentity,
                    at: source,
                    includeStatusChange: true
                )
                try requireIdentity(
                    currentArtifactIdentity,
                    at: location.url,
                    includeStatusChange: true
                )
                guard let temporary, let destination else {
                    throw RecoveryError.unverifiedOwnedFile(location.url)
                }
                let quarantine = location.isTemporary
                    ? destination
                    : temporary
                try DurableFileIO.atomicExclusiveRename(
                    from: location.url,
                    to: quarantine
                )
                try DurableFileIO.syncRenameDirectories(
                    from: location.url,
                    to: quarantine,
                    fullSync: true
                )
                let quarantinedIdentity = try fileIdentity(at: quarantine)
                guard identitiesMatch(
                    expected: currentArtifactIdentity,
                    actual: quarantinedIdentity,
                    includeStatusChange: false
                ) else {
                    throw RecoveryError.unverifiedOwnedFile(quarantine)
                }
                guard contentsEqual(source, quarantine) else {
                    throw RecoveryError.contentMismatch(source, quarantine)
                }
                try requireIdentity(
                    restoredSourceIdentity,
                    at: source,
                    includeStatusChange: true
                )
                try requireIdentity(
                    quarantinedIdentity,
                    at: quarantine,
                    includeStatusChange: true
                )
                try DurableFileIO.unlinkRegularFile(at: quarantine)
                try DurableFileIO.syncRemoval(
                    of: quarantine,
                    fullSync: true
                )
            }
            return RecoveredFileCounts()
        }

        guard let location = existingLocations.first else {
            throw RecoveryError.missingMovedFile(source)
        }
        let identity = try movedArtifactIdentity(
            file,
            state: state,
            at: location.url,
            isTemporary: location.isTemporary
        )
        try requireIdentity(identity, at: location.url)
        try restoreWithoutOverwrite(from: location.url, to: source)
        return RecoveredFileCounts(restoredFiles: 1)
    }

    private static func movedArtifactIdentity(
        _ file: PlannedFile,
        state: StateRecord?,
        at url: URL,
        isTemporary: Bool
    ) throws -> FileIdentity {
        // Before the staged checkpoint, only an inode-preserving same-volume
        // move to the reserved temporary path can be proven from the plan.
        if state?.state == .started, isTemporary {
            return file.identity
        }
        // A cross-volume move creates a new file identity. Once checkpointed,
        // that resolved identity—not the source inode—is the ownership proof at
        // either the temporary or final location.
        if state?.state == .staged || state?.state == .completed,
           let identity = state?.resolvedIdentity {
            return identity
        }
        throw RecoveryError.unverifiedOwnedFile(url)
    }

    private static func recoverTrash(
        _ file: PlannedFile,
        state: StateRecord?,
        planVersion: Int
    ) throws -> RecoveredFileCounts {
        let source = try plannedURL(
            for: file,
            role: .source,
            planVersion: planVersion
        )
        let resolvedDestination = try resolvedDestinationURL(
            from: state,
            planVersion: planVersion
        )
        if pathEntryExists(source) {
            // A pathname alone is never proof that Trash rollback succeeded.
            // A rename out and back changes ctime, so ownership recovery uses
            // the other stable identity fields here.
            try requireIdentity(file.identity, at: source)
            if let resolvedDestination,
               pathEntryExists(resolvedDestination) {
                throw RecoveryError.bothLocationsExist(source)
            }
            return RecoveredFileCounts()
        }

        if let trash = resolvedDestination {
            guard pathEntryExists(trash) else {
                throw RecoveryError.missingTrashedFile(source)
            }
            guard let identity = state?.resolvedIdentity else {
                throw RecoveryError.unverifiedOwnedFile(trash)
            }
            guard try linkCount(at: trash) == 1 else {
                throw RecoveryError.unverifiedOwnedFile(trash)
            }
            try requireIdentity(identity, at: trash)
            try restoreWithoutOverwrite(from: trash, to: source)
            return RecoveredFileCounts(restoredFiles: 1)
        }

        guard state?.state == .started,
              let trash = locateInTrash(identity: file.identity) else {
            throw RecoveryError.missingTrashedFile(source)
        }
        try restoreWithoutOverwrite(from: trash, to: source)
        return RecoveredFileCounts(restoredFiles: 1)
    }

    private static func recoverTrashRestore(
        _ file: PlannedFile,
        planVersion: Int
    ) throws -> RecoveredFileCounts {
        let source = try plannedURL(
            for: file,
            role: .source,
            planVersion: planVersion
        )
        guard file.destinationPath != nil else {
            throw RecoveryError.missingTrashedFile(source)
        }
        let trash = try plannedURL(
            for: file,
            role: .destination,
            planVersion: planVersion
        )
        let sourceExists = pathEntryExists(source)
        let trashExists = pathEntryExists(trash)
        if sourceExists && trashExists {
            throw RecoveryError.bothLocationsExist(source)
        }
        if sourceExists {
            guard try linkCount(at: source) == 1 else {
                throw RecoveryError.unverifiedOwnedFile(source)
            }
            try requireIdentity(file.identity, at: source)
            return RecoveredFileCounts()
        }
        guard trashExists else { throw RecoveryError.missingTrashedFile(source) }
        guard try linkCount(at: trash) == 1 else {
            throw RecoveryError.unverifiedOwnedFile(trash)
        }
        try requireIdentity(file.identity, at: trash)
        try restoreWithoutOverwrite(from: trash, to: source)
        return RecoveredFileCounts(restoredFiles: 1)
    }

    private static func restoreWithoutOverwrite(from: URL, to: URL) throws {
        let fm = FileManager()
        guard !pathEntryExists(to) else {
            throw RecoveryError.refusesOverwrite(to)
        }
        try fm.createDirectory(
            at: to.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try DurableFileIO.atomicExclusiveRename(from: from, to: to)
        try DurableFileIO.syncRenameDirectories(
            from: from,
            to: to,
            fullSync: true
        )
    }

    private static func validateTemporary(
        _ url: URL,
        for file: PlannedFile,
        operationID: String,
        fileIndex: Int,
        planVersion: Int
    ) throws {
        guard file.destinationPath != nil else {
            throw RecoveryError.unsafeTemporaryPath(url)
        }
        let destination = try plannedURL(
            for: file,
            role: .destination,
            planVersion: planVersion
        )
        let expected = try temporaryURL(
            beside: destination,
            operationID: operationID,
            fileIndex: fileIndex
        )
        guard exactPathsEqual(url, expected) else {
            throw RecoveryError.unsafeTemporaryPath(url)
        }
    }

    static func requireIdentity(
        _ expected: FileIdentity,
        at url: URL,
        includeStatusChange: Bool = false
    ) throws {
        let actual = try fileIdentity(at: url)
        guard identitiesMatch(
            expected: expected,
            actual: actual,
            includeStatusChange: includeStatusChange
        ) else {
            throw RecoveryError.unverifiedOwnedFile(url)
        }
    }

    static func identitiesMatch(
        expected: FileIdentity,
        actual: FileIdentity,
        includeStatusChange: Bool
    ) -> Bool {
        let volumeMatches: Bool
        if let expectedUUID = expected.volumeUUIDString {
            volumeMatches = actual.volumeUUIDString == expectedUUID
        } else {
            volumeMatches = actual.volumeRootPath == expected.volumeRootPath
                && actual.systemNumber == expected.systemNumber
        }
        return volumeMatches
            && actual.fileNumber == expected.fileNumber
            && (expected.logicalSize.map { actual.logicalSize == $0 } ?? true)
            && (
                expected.modificationTime.map {
                    actual.modificationTime == $0
                } ?? true
            )
            && (expected.birthTime.map { actual.birthTime == $0 } ?? true)
            && (
                !includeStatusChange
                    || (
                        expected.statusChangeTime.map {
                            actual.statusChangeTime == $0
                        } ?? true
                    )
            )
    }

    private static func locateInTrash(identity: FileIdentity) -> URL? {
        let fm = FileManager()
        let volumeRoot = URL(fileURLWithPath: identity.volumeRootPath)
        guard fm.fileExists(atPath: volumeRoot.path) else { return nil }

        var roots = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent(
                ".Trash",
                isDirectory: true
            ),
            volumeRoot.appendingPathComponent(
                ".Trashes/\(getuid())",
                isDirectory: true
            ),
        ]
        var seen = Set<String>()
        roots = roots.filter {
            let path = $0.standardizedFileURL.path
            return seen.insert(path).inserted && fm.fileExists(atPath: path)
        }
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let candidate as URL in enumerator {
                if (try? linkCount(at: candidate)) == 1,
                   let candidateIdentity = try? fileIdentity(at: candidate),
                   identitiesMatch(
                       expected: identity,
                       actual: candidateIdentity,
                       includeStatusChange: false
                   ) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func pendingOperationURLs(
        in root: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "operation" }
        } catch {
            throw JournalError.cannotInspectOperations(root)
        }
    }

    private static func isCreatingOperationURL(_ url: URL) -> Bool {
        guard url.pathExtension == "creating" else { return false }
        let operationID = url.deletingPathExtension().lastPathComponent
        return UUID(uuidString: operationID) != nil
            && operationID == operationID.lowercased()
    }

    private static func isRetiredOperationURL(_ url: URL) -> Bool {
        guard url.pathExtension == "retired" else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.utf8.count == 73 else { return false }
        let separator = name.index(name.startIndex, offsetBy: 36)
        guard name[separator] == "-" else { return false }
        let operationID = String(name[..<separator])
        let retirementID = String(name[name.index(after: separator)...])
        return UUID(uuidString: operationID) != nil
            && UUID(uuidString: retirementID) != nil
            && name == name.lowercased()
    }

    /// Captures the same physical-file identity used by operation plans.
    /// FolderScanner supplies already-prefetched volume facts to avoid a
    /// mounted-volume lookup for every media file.
    static func captureIdentity(
        at url: URL,
        volumeRoot: URL? = nil,
        volumeUUIDString: String? = nil
    ) throws -> FileIdentity {
        try fileIdentity(
            at: url,
            knownVolumeRoot: volumeRoot,
            knownVolumeUUIDString: volumeUUIDString
        )
    }

    private static func fileIdentity(
        at url: URL,
        knownVolumeRoot: URL? = nil,
        knownVolumeUUIDString: String? = nil
    ) throws -> FileIdentity {
        let fm = FileManager()
        var info = Darwin.stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &info)
        }
        let resourceValues = try? url.resourceValues(forKeys: [
            .volumeURLKey,
            .volumeUUIDStringKey,
        ])
        guard status == 0,
              let volume = knownVolumeRoot
                ?? resourceValues?.volume
                ?? volumeRoot(containing: url, fileManager: fm) else {
            throw JournalError.missingFileIdentity(url)
        }
        return FileIdentity(
            volumeRootPath: volume.standardizedFileURL.path,
            volumeUUIDString:
                knownVolumeUUIDString ?? resourceValues?.volumeUUIDString,
            systemNumber: UInt64(info.st_dev),
            fileNumber: UInt64(info.st_ino),
            logicalSize: info.st_size,
            modificationTime: FileIdentity.Timestamp(
                seconds: Int64(info.st_mtimespec.tv_sec),
                nanoseconds: Int64(info.st_mtimespec.tv_nsec)
            ),
            statusChangeTime: FileIdentity.Timestamp(
                seconds: Int64(info.st_ctimespec.tv_sec),
                nanoseconds: Int64(info.st_ctimespec.tv_nsec)
            ),
            birthTime: FileIdentity.Timestamp(
                seconds: Int64(info.st_birthtimespec.tv_sec),
                nanoseconds: Int64(info.st_birthtimespec.tv_nsec)
            )
        )
    }

    private static func linkCount(at url: URL) throws -> UInt64 {
        var info = Darwin.stat()
        var status: Int32
        var failure: Int32 = 0
        status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            var result: Int32
            repeat {
                result = Darwin.lstat(path, &info)
            } while result != 0 && errno == EINTR
            if result != 0 { failure = errno }
            return result
        }
        guard status == 0 else {
            throw DurableFileIO.IOError.system(
                operation: "read link count",
                path: url.path,
                code: failure
            )
        }
        return UInt64(info.st_nlink)
    }

    private static func volumeRoot(
        containing url: URL,
        fileManager: FileManager
    ) -> URL? {
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        )?
        .map { $0.resolvingSymlinksInPath().standardizedFileURL }
        .filter {
            let root = $0.path
            return filePath == root
                || filePath.hasPrefix(root == "/" ? "/" : root + "/")
        }
        .max(by: { $0.path.count < $1.path.count })
    }

    /// Exact, lexical filesystem bytes used as dictionary/set identity outside
    /// this type as well. Returning nil is a fail-closed signal: callers must
    /// not substitute `URL.path`, whose Unicode normalization can name a
    /// different directory entry.
    static func exactPathBytes(for url: URL) -> Data? {
        try? validatedPathBytes(for: url)
    }

    static func exactPathsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsBytes = exactPathBytes(for: lhs),
              let rhsBytes = exactPathBytes(for: rhs) else {
            return false
        }
        return lhsBytes == rhsBytes
    }

    /// Resolves symlinks with POSIX `realpath` while retaining the exact
    /// filesystem representation of every non-symlink path component.
    /// Foundation's `resolvingSymlinksInPath().standardizedFileURL` can
    /// canonically decompose a user-selected Unicode directory name.
    static func resolvingSymlinksExactly(_ url: URL) throws -> URL {
        try exactURL(
            fromFileSystemPathBytes: resolvedFileSystemPathBytes(
                try validatedPathBytes(for: url)
            )
        )
    }

    /// `URL.appendingPathComponent` also normalizes the existing base path.
    /// Build export targets from raw directory bytes so the selected folder
    /// remains byte-for-byte unchanged.
    static func appendingPathComponentExactly(
        _ component: String,
        to directory: URL
    ) throws -> URL {
        let componentBytes = Data(component.utf8)
        guard !componentBytes.isEmpty,
              !componentBytes.contains(0),
              !componentBytes.contains(UInt8(ascii: "/")),
              componentBytes != Data(".".utf8),
              componentBytes != Data("..".utf8) else {
            throw JournalError.invalidFileSystemPath
        }
        var pathBytes = try validatedPathBytes(for: directory)
        if pathBytes.count > 1 {
            pathBytes.append(UInt8(ascii: "/"))
        }
        pathBytes.append(componentBytes)
        return try exactURL(fromFileSystemPathBytes: pathBytes)
    }

    private static func validatedPathBytes(for url: URL) throws -> Data {
        guard let bytes = fileSystemRepresentationBytes(for: url),
              rawPathIsLexicallyAbsoluteAndCanonical(bytes),
              let roundTripped = try? exactURL(
                fromFileSystemPathBytes: bytes
              ),
              fileSystemRepresentationBytes(for: roundTripped) == bytes else {
            throw JournalError.invalidFileSystemPath
        }
        return bytes
    }

    private static func fileSystemRepresentationBytes(
        for url: URL
    ) -> Data? {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return nil }
            return Data(bytes: pointer, count: strlen(pointer))
        }
    }

    private static func exactURL(
        fromFileSystemPathBytes bytes: Data
    ) throws -> URL {
        guard rawPathIsLexicallyAbsoluteAndCanonical(bytes) else {
            throw JournalError.invalidFileSystemPath
        }
        var terminated = bytes
        terminated.append(0)
        let url = terminated.withUnsafeBytes { rawBuffer -> URL in
            let pointer = rawBuffer.baseAddress!
                .assumingMemoryBound(to: CChar.self)
            return URL(
                fileURLWithFileSystemRepresentation: pointer,
                isDirectory: false,
                relativeTo: nil
            )
        }
        // Foundation cannot represent every byte sequence on every supported
        // filesystem. Never accept its U+FFFD replacement as authority for the
        // original raw name: leave such a journal retryable and untouched.
        guard fileSystemRepresentationBytes(for: url) == bytes else {
            throw JournalError.invalidFileSystemPath
        }
        return url
    }

    private static func plannedURL(
        for file: PlannedFile,
        role: PlannedPathRole,
        planVersion: Int
    ) throws -> URL {
        let legacyPath: String?
        let exactBytes: Data?
        switch role {
        case .source:
            legacyPath = file.sourcePath
            exactBytes = file.sourcePathBytes
        case .destination:
            legacyPath = file.destinationPath
            exactBytes = file.destinationPathBytes
        case .temporary:
            legacyPath = file.temporaryPath
            exactBytes = file.temporaryPathBytes
        }
        if planVersion >= 3 {
            guard let exactBytes else {
                throw JournalError.invalidFileSystemPath
            }
            return try exactURL(fromFileSystemPathBytes: exactBytes)
        }
        guard let legacyPath else {
            throw JournalError.invalidFileSystemPath
        }
        return URL(fileURLWithPath: legacyPath)
    }

    private static func resolvedDestinationURL(
        from state: StateRecord?,
        planVersion: Int
    ) throws -> URL? {
        guard let state else { return nil }
        if planVersion >= 3 {
            switch (
                state.resolvedDestinationPath,
                state.resolvedDestinationPathBytes
            ) {
            case (nil, nil):
                return nil
            case let (path?, bytes?):
                let url = try exactURL(
                    fromFileSystemPathBytes: bytes
                )
                guard Data(path.utf8) == Data(url.path.utf8) else {
                    throw JournalError.invalidFileSystemPath
                }
                return url
            default:
                throw JournalError.invalidFileSystemPath
            }
        }
        return state.resolvedDestinationPath.map(URL.init(fileURLWithPath:))
    }

    private static func temporaryURL(
        beside destination: URL,
        operationID: String,
        fileIndex: Int
    ) throws -> URL {
        let destinationBytes = try validatedPathBytes(for: destination)
        return try exactURL(
            fromFileSystemPathBytes: temporaryPathBytes(
                beside: destinationBytes,
                operationID: operationID,
                fileIndex: fileIndex
            )
        )
    }

    private static func temporaryPathBytes(
        beside destinationBytes: Data,
        operationID: String,
        fileIndex: Int
    ) throws -> Data {
        guard rawPathIsLexicallyAbsoluteAndCanonical(destinationBytes),
              let separator = destinationBytes.lastIndex(
                of: UInt8(ascii: "/")
              ) else {
            throw JournalError.invalidFileSystemPath
        }
        var result = Data(destinationBytes[..<separator])
        if result.isEmpty { result.append(UInt8(ascii: "/")) }
        if result.count > 1 { result.append(UInt8(ascii: "/")) }
        result.append(contentsOf: Data(
            ".louppe-\(operationID)-\(fileIndex).partial".utf8
        ))
        guard rawPathIsLexicallyAbsoluteAndCanonical(result) else {
            throw JournalError.invalidFileSystemPath
        }
        return result
    }

    private static func rawPathIsLexicallyAbsoluteAndCanonical(
        _ bytes: Data
    ) -> Bool {
        let slash = UInt8(ascii: "/")
        guard bytes.first == slash,
              !bytes.contains(0) else {
            return false
        }
        if bytes.count == 1 { return true }
        guard bytes.last != slash else { return false }
        var component = Data()
        for byte in bytes.dropFirst() {
            if byte == slash {
                guard !component.isEmpty,
                      component != Data(".".utf8),
                      component != Data("..".utf8) else {
                    return false
                }
                component.removeAll(keepingCapacity: true)
            } else {
                component.append(byte)
            }
        }
        return !component.isEmpty
            && component != Data(".".utf8)
            && component != Data("..".utf8)
    }

    /// Resolves every existing symlink component while retaining the raw bytes
    /// of any nonexistent suffix. Unlike Foundation standardization, POSIX
    /// `realpath` does not canonically decompose a distinct Unicode spelling.
    private static func resolvedFileSystemPathBytes(
        _ bytes: Data
    ) throws -> Data {
        guard rawPathIsLexicallyAbsoluteAndCanonical(bytes) else {
            throw JournalError.invalidFileSystemPath
        }
        let slash = UInt8(ascii: "/")
        var candidate = bytes
        var missingComponents: [Data] = []
        while true {
            let resolved = rawRealPath(candidate)
            if let path = resolved.path {
                var result = path
                for component in missingComponents {
                    if result.count > 1 { result.append(slash) }
                    result.append(component)
                }
                guard rawPathIsLexicallyAbsoluteAndCanonical(result) else {
                    throw JournalError.invalidFileSystemPath
                }
                return result
            }
            guard resolved.error == ENOENT || resolved.error == ENOTDIR,
                  candidate.count > 1,
                  let separator = candidate.lastIndex(of: slash) else {
                throw JournalError.invalidFileSystemPath
            }
            missingComponents.insert(
                Data(candidate[candidate.index(after: separator)...]),
                at: 0
            )
            candidate = separator == candidate.startIndex
                ? Data([slash])
                : Data(candidate[..<separator])
        }
    }

    private static func rawRealPath(
        _ bytes: Data
    ) -> (path: Data?, error: Int32) {
        var terminated = bytes
        terminated.append(0)
        var failure: Int32 = 0
        let pointer: UnsafeMutablePointer<CChar>? =
            terminated.withUnsafeBytes { rawBuffer in
                errno = 0
                let result = Darwin.realpath(
                    rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                    nil
                )
                if result == nil { failure = errno }
                return result
            }
        guard let pointer else { return (nil, failure) }
        defer { free(pointer) }
        return (Data(bytes: pointer, count: strlen(pointer)), 0)
    }

    private static func pathIsEqualToOrDescendantOfRoot(
        path: Data,
        root: Data
    ) -> Bool {
        if path == root { return true }
        var prefix = root
        if prefix.count > 1 { prefix.append(UInt8(ascii: "/")) }
        return path.starts(with: prefix)
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        var info = Darwin.stat()
        var failure: Int32 = 0
        let status: Int32 = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else {
                failure = EINVAL
                return -1
            }
            var result: Int32
            repeat {
                result = Darwin.lstat(pointer, &info)
            } while result != 0 && errno == EINTR
            if result != 0 { failure = errno }
            return result
        }
        if status == 0 { return true }
        // Uncertainty must behave like an occupied entry so recovery never
        // overwrites through a path it could not inspect.
        return failure != ENOENT && failure != ENOTDIR
    }

    /// Byte comparison that opens the exact URL representations instead of
    /// routing through `String` paths, which can normalize to a sibling.
    static func contentsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = openExactRegularFileForReading(lhs) else {
            return false
        }
        defer { Darwin.close(left.descriptor) }
        guard let right = openExactRegularFileForReading(rhs) else {
            return false
        }
        defer { Darwin.close(right.descriptor) }
        guard left.info.st_size == right.info.st_size else { return false }
        if left.info.st_dev == right.info.st_dev,
           left.info.st_ino == right.info.st_ino {
            return true
        }

        var leftBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        var rightBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let leftCount = readRetryingInterrupts(
                descriptor: left.descriptor,
                into: &leftBuffer
            )
            let rightCount = readRetryingInterrupts(
                descriptor: right.descriptor,
                into: &rightBuffer
            )
            guard leftCount >= 0, leftCount == rightCount else { return false }
            if leftCount == 0 { return true }
            guard leftBuffer[..<leftCount] == rightBuffer[..<rightCount] else {
                return false
            }
        }
    }

    private static func openExactRegularFileForReading(
        _ url: URL
    ) -> (descriptor: Int32, info: Darwin.stat)? {
        var descriptor: Int32 = -1
        var openFailure: Int32 = 0
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else {
                openFailure = EINVAL
                return
            }
            repeat {
                descriptor = Darwin.open(
                    pointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                )
            } while descriptor < 0 && errno == EINTR
            if descriptor < 0 { openFailure = errno }
        }
        guard descriptor >= 0 else {
            _ = openFailure
            return nil
        }
        var info = Darwin.stat()
        var status: Int32
        repeat {
            status = Darwin.fstat(descriptor, &info)
        } while status != 0 && errno == EINTR
        guard status == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            return nil
        }
        return (descriptor, info)
    }

    private static func readRetryingInterrupts(
        descriptor: Int32,
        into buffer: inout [UInt8]
    ) -> Int {
        var count: Int
        repeat {
            count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }
        } while count < 0 && errno == EINTR
        return count
    }

    private static func decodePlan(at operationURL: URL) throws -> Plan {
        let planURL = operationURL.appendingPathComponent("plan.json")
        do {
            guard isDirectoryWithoutFollowingSymlink(operationURL) else {
                throw JournalError.corruptPlan(operationURL)
            }
            let plan = try decoder.decode(
                Plan.self,
                from: DurableFileIO.readRegularFile(
                    at: planURL,
                    maximumBytes: maximumPlanBytes
                )
            )
            guard (1...3).contains(plan.version),
                  operationURL.lastPathComponent == "\(plan.operationID).operation" else {
                throw JournalError.corruptPlan(planURL)
            }
            let allowsEmptyLegacyCommit =
                plan.version == 1
                && plan.files.isEmpty
                && (try? DurableFileIO.readRegularFile(
                    at: operationURL.appendingPathComponent("committed"),
                    maximumBytes: maximumCommitBytes
                )) == legacyCommitMarker
            try validatePlan(
                plan,
                at: operationURL,
                allowsEmptyLegacyCommit: allowsEmptyLegacyCommit
            )
            return plan
        } catch {
            throw JournalError.corruptPlan(planURL)
        }
    }

    private static func validatePlan(
        _ plan: Plan,
        at operationURL: URL,
        allowsEmptyLegacyCommit: Bool = false
    ) throws {
        guard (allowsEmptyLegacyCommit || !plan.files.isEmpty),
              UUID(uuidString: plan.operationID) != nil,
              plan.operationID == plan.operationID.lowercased() else {
            throw JournalError.corruptPlan(operationURL)
        }
        let journalRootURL = operationURL.deletingLastPathComponent()
        let journalRootPath = journalRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let journalRootBytes = try resolvedFileSystemPathBytes(
            validatedPathBytes(for: journalRootURL)
        )
        var pathBytes = Set<Data>()
        var resolvedPathBytes = Set<Data>()
        var sourceFileIdentities = Set<String>()
        var ownedFileIdentities = Set<String>()

        func isInJournalRoot(
            path: String,
            bytes: Data
        ) -> Bool {
            if plan.version >= 3 {
                return pathIsEqualToOrDescendantOfRoot(
                    path: bytes,
                    root: journalRootBytes
                )
            }
            return path == journalRootPath
                || path.hasPrefix(journalRootPath + "/")
        }

        func registerManipulatedPath(
            _ path: String,
            exactBytes: Data?,
            role: ManipulatedPathRole
        ) -> Bool {
            let url: URL
            let registeredBytes: Data
            let registeredPath: String
            if plan.version >= 3 {
                guard let exactBytes,
                      let exactURL = try? exactURL(
                        fromFileSystemPathBytes: exactBytes
                      ),
                      Data(path.utf8) == Data(exactURL.path.utf8) else {
                    return false
                }
                url = exactURL
                registeredBytes = exactBytes
                registeredPath = path
            } else {
                guard (path as NSString).isAbsolutePath else { return false }
                let legacyURL = URL(fileURLWithPath: path)
                let standardizedPath = legacyURL.standardizedFileURL.path
                guard Data(path.utf8) == Data(standardizedPath.utf8) else {
                    return false
                }
                url = legacyURL
                registeredBytes = Data(standardizedPath.utf8)
                registeredPath = standardizedPath
            }
            guard !isInJournalRoot(
                path: registeredPath,
                bytes: registeredBytes
            ), pathBytes.insert(registeredBytes).inserted else {
                return false
            }

            // Resolve existing symlink components as a second alias boundary.
            // Version 3 does this through raw `realpath` bytes so merely asking
            // for canonicalization cannot fold NFC and NFD siblings together.
            let resolvedBytes: Data
            let resolvedPath: String
            if plan.version >= 3 {
                guard let bytes = try? resolvedFileSystemPathBytes(
                    registeredBytes
                ), let resolvedURL = try? exactURL(
                    fromFileSystemPathBytes: bytes
                ) else {
                    return false
                }
                resolvedBytes = bytes
                resolvedPath = resolvedURL.path
            } else {
                resolvedPath = url
                    .resolvingSymlinksInPath()
                    .standardizedFileURL.path
                resolvedBytes = Data(resolvedPath.utf8)
            }
            guard !isInJournalRoot(
                path: resolvedPath,
                bytes: resolvedBytes
            ), resolvedPathBytes.insert(resolvedBytes).inserted else {
                return false
            }

            // Case aliases and hard links can still resolve to different
            // strings. When multiple planned paths currently exist, reject a
            // shared inode rather than letting recovery remove through either
            // name.
            var info = Darwin.stat()
            var lstatError: Int32 = 0
            let status: Int32 = url.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else { return Int32(-1) }
                let result = Darwin.lstat(pointer, &info)
                if result != 0 {
                    lstatError = errno
                }
                return result
            }
            if status == 0 {
                let identity = "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))"
                switch role {
                case .source:
                    guard !ownedFileIdentities.contains(identity) else {
                        return false
                    }
                    // Copying two hard-linked directory entries is safe.
                    // Renaming or trashing either entry changes the shared
                    // inode's ctime, which would invalidate its sibling's
                    // checkpoint and make crash recovery ambiguous. Mutating
                    // batches therefore fail before their first file change.
                    guard plan.kind == .exportCopy
                            || !sourceFileIdentities.contains(identity) else {
                        return false
                    }
                    sourceFileIdentities.insert(identity)
                case .owned:
                    guard !sourceFileIdentities.contains(identity),
                          ownedFileIdentities.insert(identity).inserted else {
                        return false
                    }
                }
            } else if lstatError != ENOENT && lstatError != ENOTDIR {
                return false
            }
            return true
        }

        for (index, file) in plan.files.enumerated() {
            guard !file.itemID.isEmpty,
                  (file.identity.volumeRootPath as NSString).isAbsolutePath,
                  registerManipulatedPath(
                    file.sourcePath,
                    exactBytes: file.sourcePathBytes,
                    role: .source
                  ) else {
                throw JournalError.corruptPlan(operationURL)
            }

            switch plan.kind {
            case .exportCopy, .exportMove:
                guard let destinationPath = file.destinationPath,
                      let temporaryPath = file.temporaryPath else {
                    throw JournalError.corruptPlan(operationURL)
                }
                let temporaryMatches: Bool
                if plan.version >= 3 {
                    guard let destinationBytes = file.destinationPathBytes,
                          let temporaryBytes = file.temporaryPathBytes,
                          let expectedTemporary = try? temporaryPathBytes(
                            beside: destinationBytes,
                            operationID: plan.operationID,
                            fileIndex: index
                          ) else {
                        throw JournalError.corruptPlan(operationURL)
                    }
                    temporaryMatches = temporaryBytes == expectedTemporary
                } else {
                    let destination = URL(
                        fileURLWithPath: destinationPath
                    )
                    let expectedTemporary = destination
                        .deletingLastPathComponent()
                        .appendingPathComponent(
                            ".louppe-\(plan.operationID)-\(index).partial"
                        )
                        .standardizedFileURL.path
                    temporaryMatches = Data(temporaryPath.utf8)
                        == Data(expectedTemporary.utf8)
                }
                guard temporaryMatches,
                      registerManipulatedPath(
                          destinationPath,
                          exactBytes: file.destinationPathBytes,
                          role: .owned
                      ),
                      registerManipulatedPath(
                          temporaryPath,
                          exactBytes: file.temporaryPathBytes,
                          role: .owned
                      ) else {
                    throw JournalError.corruptPlan(operationURL)
                }
            case .moveToTrash:
                guard file.destinationPath == nil,
                      file.temporaryPath == nil,
                      plan.version < 3
                        || (
                            file.destinationPathBytes == nil
                                && file.temporaryPathBytes == nil
                        ) else {
                    throw JournalError.corruptPlan(operationURL)
                }
            case .restoreFromTrash:
                guard let destinationPath = file.destinationPath,
                      file.temporaryPath == nil,
                      plan.version < 3
                        || file.temporaryPathBytes == nil,
                      registerManipulatedPath(
                          destinationPath,
                          exactBytes: file.destinationPathBytes,
                          role: .owned
                      ) else {
                    throw JournalError.corruptPlan(operationURL)
                }
            }
        }
    }

    private static func validateCommit(
        at url: URL,
        for plan: Plan
    ) throws {
        do {
            let data = try DurableFileIO.readRegularFile(
                at: url,
                maximumBytes: maximumCommitBytes
            )
            // Version-1 journals from already installed builds used this exact
            // marker. It is accepted only with the stricter semantic plan
            // validation above; every newly created version-2-or-newer plan requires
            // the operation-bound digest record.
            if plan.version == 1,
               data == legacyCommitMarker {
                return
            }
            let record = try decoder.decode(
                CommitRecord.self,
                from: data
            )
            let rawDigest = try planDigest(
                at: url.deletingLastPathComponent()
                    .appendingPathComponent("plan.json")
            )
            let matchesLegacySemanticDigest: Bool
            if plan.version == 1 {
                matchesLegacySemanticDigest =
                    record.planDigest == (try semanticPlanDigest(plan))
            } else {
                matchesLegacySemanticDigest = false
            }
            guard record.version == 1,
                  record.operationID == plan.operationID,
                  record.planDigest == rawDigest
                    || matchesLegacySemanticDigest else {
                throw JournalError.corruptPlan(url)
            }
        } catch {
            throw JournalError.corruptPlan(url)
        }
    }

    private static func planDigest(at planURL: URL) throws -> String {
        digest(try DurableFileIO.readRegularFile(
            at: planURL,
            maximumBytes: maximumPlanBytes
        ))
    }

    private static func semanticPlanDigest(_ plan: Plan) throws -> String {
        digest(try encoder.encode(plan))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // A 100,000-file operation with long Unicode paths can legitimately be
    // well above 64 MiB. Keep the read finite without rejecting the scale the
    // prepared-session index and export architecture are designed to handle.
    private static let maximumPlanBytes = 512 * 1024 * 1024
    private static let maximumStateBytes = 64 * 1024
    private static let maximumCommitBytes = 64 * 1024
    private static let legacyCommitMarker = Data("committed\n".utf8)

    private static func readState(
        at operationURL: URL,
        index: Int
    ) -> StateRecord? {
        let url = operationURL
            .appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(String(format: "%08d.json", index))
        guard let data = try? DurableFileIO.readRegularFile(
            at: url,
            maximumBytes: maximumStateBytes
        ) else { return nil }
        return try? decoder.decode(StateRecord.self, from: data)
    }

    private static func isDirectoryWithoutFollowingSymlink(_ url: URL) -> Bool {
        var info = Darwin.stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &info)
        }
        return status == 0
            && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private enum RecoveryError: LocalizedError {
        case missingMovedFile(URL)
        case missingCopySource(URL)
        case missingTrashedFile(URL)
        case bothLocationsExist(URL)
        case multipleRecoveryCandidates(URL)
        case refusesOverwrite(URL)
        case unsafeTemporaryPath(URL)
        case unverifiedOwnedFile(URL)
        case contentMismatch(URL, URL)

        var errorDescription: String? {
            switch self {
            case .missingMovedFile(let source):
                return "The interrupted move couldn't locate \(source.lastPathComponent)."
            case .missingCopySource(let source):
                return "Recovery couldn't verify the original \(source.lastPathComponent), so it preserved every copy."
            case .missingTrashedFile(let source):
                return "The interrupted Trash operation couldn't locate \(source.lastPathComponent)."
            case .bothLocationsExist(let source):
                return "\(source.lastPathComponent) exists in both locations; Louppe left both untouched."
            case .multipleRecoveryCandidates(let source):
                return "Recovery found multiple possible copies of \(source.lastPathComponent), so it left every file untouched."
            case .refusesOverwrite(let url):
                return "Recovery refused to overwrite \(url.lastPathComponent)."
            case .unsafeTemporaryPath:
                return "Recovery found an invalid temporary path and left it untouched."
            case .unverifiedOwnedFile(let url):
                return "Recovery couldn't verify that \(url.lastPathComponent) belongs to the interrupted operation, so it left the file untouched."
            case .contentMismatch(let source, let copy):
                return "Recovery found different contents in \(source.lastPathComponent) and \(copy.lastPathComponent), so it preserved both files."
            }
        }
    }

    private static var defaultDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent(
            "Louppe/Operations",
            isDirectory: true
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// One process may own the operation root at a time. The OS releases this
    /// advisory lock automatically on crash, after which launch recovery can
    /// safely inspect journals. The app-level single-instance declaration is
    /// only a UX defense; this lock is the correctness boundary.
    fileprivate final class OperationLock {
        private var descriptor: Int32

        private init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        static func acquire(in root: URL) throws -> OperationLock {
            let path = root.appendingPathComponent(".operation.lock").path
            var descriptor: Int32
            repeat {
                descriptor = Darwin.open(
                    path,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK
                        | O_NOFOLLOW,
                    mode_t(0o600)
                )
            } while descriptor < 0 && errno == EINTR
            guard descriptor >= 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw JournalError.operationInUse
                }
                throw JournalError.cannotLockOperations(code)
            }
            var info = Darwin.stat()
            var status: Int32
            repeat {
                status = Darwin.fstat(descriptor, &info)
            } while status != 0 && errno == EINTR
            guard status == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_nlink == 1 else {
                let code = status == 0 ? EFTYPE : errno
                Darwin.close(descriptor)
                throw JournalError.cannotLockOperations(code)
            }
            return OperationLock(descriptor: descriptor)
        }

        func release() {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }

        deinit {
            release()
        }
    }
}
