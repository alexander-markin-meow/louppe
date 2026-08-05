import CryptoKit
import Darwin
import Foundation

/// Narrow persistence boundary used by `SessionStore`. Keeping the actor
/// behind this protocol lets concurrency tests pause writes at exact points
/// instead of relying on disk speed or scheduler timing.
protocol SessionPersistenceClient: Sendable {
    func save(
        _ session: SessionFile,
        for folder: URL,
        sequence: UInt64,
        access: SessionPersistence.AccessContext
    ) async -> SessionPersistence.SaveResult

    func read(
        for folder: URL,
        folderIdentity: SessionPersistence.SourceFolderIdentity
    ) async -> SessionPersistence.ReadResult
}

/// Serializes sidecar reads and writes away from the main actor.
///
/// Save requests carry a monotonically increasing sequence number. This makes
/// fire-and-forget saves safe: if task scheduling delivers an older snapshot
/// late, it cannot overwrite a newer snapshot for the same folder.
actor SessionPersistence: SessionPersistenceClient {
    private static let maximumSnapshotBytes = 512 * 1_024 * 1_024
    struct SourceFolderIdentity: Hashable, Sendable {
        let volumeRootPath: String
        let volumeUUIDString: String?
        let systemNumber: UInt64
        let fileNumber: UInt64
        let birthTime: FileOperationJournal.FileIdentity.Timestamp
        /// lstat identities for every exact path component that existed when
        /// this access began. Equality/storage remain folder-identity based;
        /// this chain only distinguishes an absent path from a replacement.
        private let pathEntries: [PathEntry]

        private struct PathEntry: Hashable, Sendable {
            let pathBytes: Data
            let systemNumber: UInt64
            let fileNumber: UInt64
            let fileType: UInt32
        }

        fileprivate enum PathState {
            case matching
            case unavailable
            case changed
        }

        static func capture(at folder: URL) throws -> Self {
            // The URL supplied by FolderScanner is the pathname authority.
            // Converting it through `.path`, standardization, or symlink
            // resolution can redirect an NFC spelling to its NFD sibling on a
            // normalization-sensitive volume. Inspect that exact URL instead.
            let values = try folder.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let identity = try FileOperationJournal.captureIdentity(at: folder)
            guard let birthTime = identity.birthTime else {
                throw CocoaError(.fileReadUnknown)
            }
            return Self(
                volumeRootPath: identity.volumeRootPath,
                volumeUUIDString: identity.volumeUUIDString,
                systemNumber: identity.systemNumber,
                fileNumber: identity.fileNumber,
                birthTime: birthTime,
                pathEntries: try capturePathEntries(for: folder)
            )
        }

        private static func fileSystemPathBytes(
            for folder: URL
        ) throws -> Data {
            try folder.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                return Data(bytes: pointer, count: strlen(pointer))
            }
        }

        private static func capturePathEntries(
            for folder: URL
        ) throws -> [PathEntry] {
            let path = try fileSystemPathBytes(for: folder)
            let bytes = [UInt8](path)
            guard bytes.first == UInt8(ascii: "/"),
                  bytes.count > 1 else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            var prefixes = [Data([UInt8(ascii: "/")])]
            for index in 1..<bytes.count where bytes[index] == UInt8(ascii: "/") {
                prefixes.append(Data(bytes[..<index]))
            }
            prefixes.append(path)
            return try prefixes.map { prefix in
                let (status, _) = lstatPath(prefix)
                guard let status else {
                    throw CocoaError(.fileReadUnknown)
                }
                return PathEntry(
                    pathBytes: prefix,
                    systemNumber: UInt64(status.st_dev),
                    fileNumber: UInt64(status.st_ino),
                    fileType: UInt32(status.st_mode & mode_t(S_IFMT))
                )
            }
        }

        private static func lstatPath(
            _ path: Data
        ) -> (Darwin.stat?, Int32) {
            var terminated = [UInt8](path)
            terminated.append(0)
            var info = Darwin.stat()
            var failure: Int32 = 0
            let result = terminated.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(
                    to: CChar.self,
                    capacity: buffer.count
                ) { pointer in
                    var status: Int32
                    repeat {
                        status = Darwin.lstat(pointer, &info)
                    } while status != 0 && errno == EINTR
                    if status != 0 { failure = errno }
                    return status
                }
            }
            return result == 0 ? (info, 0) : (nil, failure)
        }

        fileprivate func pathState(
            at folder: URL,
            allowSourceVolumeDeviceRemapping: Bool
        ) -> PathState {
            guard let requestedPath = try? Self.fileSystemPathBytes(
                for: folder
            ), requestedPath == pathEntries.last?.pathBytes else {
                return .changed
            }
            for expected in pathEntries {
                let (current, failure) = Self.lstatPath(expected.pathBytes)
                guard let current else {
                    switch failure {
                    case ENOENT, ENODEV, ENXIO, ESTALE:
                        return .unavailable
                    default:
                        return .changed
                    }
                }
                // A real removable volume can receive a new st_dev number on
                // remount. When that volume has a UUID, its UUID is the volume
                // authority and `sourceFolderState` verifies it immediately
                // after this path walk. Keep strict device checks for every
                // ancestor outside that UUID-owned source volume.
                let sourceVolumeCanRemount =
                    allowSourceVolumeDeviceRemapping
                    && volumeUUIDString != nil
                    && expected.systemNumber == systemNumber
                guard (sourceVolumeCanRemount
                        || UInt64(current.st_dev) == expected.systemNumber),
                      UInt64(current.st_ino) == expected.fileNumber,
                      UInt32(current.st_mode & mode_t(S_IFMT))
                        == expected.fileType else {
                    return .changed
                }
            }
            return .matching
        }

        func matches(folder: URL) -> Bool {
            guard let current = try? Self.capture(at: folder) else { return false }
            guard self == current else { return false }
            return pathState(
                at: folder,
                allowSourceVolumeDeviceRemapping: true
            ) == .matching
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            let sameVolume: Bool
            if let uuid = lhs.volumeUUIDString {
                sameVolume = rhs.volumeUUIDString == uuid
            } else {
                sameVolume = rhs.volumeUUIDString == nil
                    && rhs.volumeRootPath == lhs.volumeRootPath
                    && rhs.systemNumber == lhs.systemNumber
            }
            return sameVolume
                && rhs.fileNumber == lhs.fileNumber
                && rhs.birthTime == lhs.birthTime
        }

        func hash(into hasher: inout Hasher) {
            if let volumeUUIDString {
                hasher.combine(0)
                hasher.combine(volumeUUIDString)
            } else {
                hasher.combine(1)
                hasher.combine(volumeRootPath)
                hasher.combine(systemNumber)
            }
            hasher.combine(fileNumber)
            hasher.combine(birthTime.seconds)
            hasher.combine(birthTime.nanoseconds)
        }

#if DEBUG
        /// Models macOS assigning the same UUID-owned card a different st_dev
        /// after remount; ordinary temporary test folders cannot trigger that
        /// kernel behavior deterministically.
        func remappingSourceSystemNumberForTesting(
            to replacement: UInt64
        ) -> Self {
            let previous = systemNumber
            let remappedEntries = pathEntries.map { entry in
                guard entry.systemNumber == previous else { return entry }
                return PathEntry(
                    pathBytes: entry.pathBytes,
                    systemNumber: replacement,
                    fileNumber: entry.fileNumber,
                    fileType: entry.fileType
                )
            }
            return Self(
                volumeRootPath: volumeRootPath,
                volumeUUIDString: volumeUUIDString,
                systemNumber: replacement,
                fileNumber: fileNumber,
                birthTime: birthTime,
                pathEntries: remappedEntries
            )
        }
#endif

        fileprivate var storageKey: String {
            let volume = volumeUUIDString.map { "uuid:\($0)" }
                ?? "legacy:\(volumeRootPath):\(systemNumber)"
            return SessionPersistence.digest(
                Data(
                    "\(volume)|\(fileNumber)|\(birthTime.seconds)|\(birthTime.nanoseconds)"
                        .utf8
                )
            )
        }
    }

    enum SidecarRevision: Sendable, Equatable {
        case absent
        case content(String)
        case unavailable
    }

    struct AccessContext: Sendable, Equatable {
        let id: UUID
        let folderIdentity: SourceFolderIdentity
        let sidecarRevision: SidecarRevision
        /// Exact raw-byte digest of the identity-keyed fallback observed by
        /// `read`. It participates in the same locked lineage as the sidecar,
        /// which prevents two writers from racing when the folder is read-only.
        let backupRevision: SidecarRevision
        /// Highest durable generation observed when this exact folder access
        /// began. The actor advances its private copy only after a sidecar or
        /// backup save succeeds.
        let initialSnapshotGeneration: UInt64

        init(
            id: UUID,
            folderIdentity: SourceFolderIdentity,
            sidecarRevision: SidecarRevision,
            backupRevision: SidecarRevision = .absent,
            initialSnapshotGeneration: UInt64 = 0
        ) {
            self.id = id
            self.folderIdentity = folderIdentity
            self.sidecarRevision = sidecarRevision
            self.backupRevision = backupRevision
            self.initialSnapshotGeneration = initialSnapshotGeneration
        }
    }

    enum SnapshotLocation: String, Sendable {
        case sidecar
        case backup
    }

    enum FailureReason: String, Sendable, Equatable {
        case permissionDenied
        case outOfSpace
        case volumeUnavailable
        case busy
        case encoding
        case other
    }

    struct SaveFailure: Sendable, Equatable {
        let sidecar: FailureReason
        let backup: FailureReason
    }

    enum SaveResult: Sendable, Equatable {
        case savedToSidecar
        case savedToBackup(sidecarFailure: FailureReason)
        case failed(SaveFailure)
        /// The proposed snapshot violates the reader's own safety contract.
        /// No existing sidecar or backup was touched.
        case rejectedInvalidSnapshot
        /// The selected path now identifies another directory or volume.
        /// Neither its sidecar nor either folder's backup was touched.
        case sourceFolderChanged
        /// The sidecar changed after this session read it. Preserve both
        /// versions until the photographer can reload/reconcile them.
        case sidecarChanged
        /// A newer sequence for this folder already reached stable storage.
        case superseded

        var canDiscardInMemoryState: Bool {
            switch self {
            case .savedToSidecar, .savedToBackup, .superseded:
                return true
            case .failed, .rejectedInvalidSnapshot,
                 .sourceFolderChanged, .sidecarChanged:
                return false
            }
        }
    }

    enum ReadProblem: Sendable, Equatable {
        case unreadable(SnapshotLocation, FailureReason)
        case corrupt(SnapshotLocation)
        case unsupportedVersion(SnapshotLocation, Int)
        case differentSourceFolder(SnapshotLocation)
        case invalidEntry(SnapshotLocation)
        case sourceFolderChanged
        case sidecarChanged
    }

    struct ReadResult: Sendable {
        let session: SessionFile?
        let origin: SnapshotLocation?
        let problems: [ReadProblem]
        let access: AccessContext?
        /// True only for the obsolete path-keyed backup format. Schema-4
        /// ratings from that unowned location must prove at least one exact
        /// physical file in SessionStore before the snapshot is trusted.
        let requiresPhysicalIdentityProof: Bool

        init(
            session: SessionFile?,
            origin: SnapshotLocation?,
            problems: [ReadProblem],
            access: AccessContext? = nil,
            requiresPhysicalIdentityProof: Bool = false
        ) {
            self.session = session
            self.origin = origin
            self.problems = problems
            self.access = access
            self.requiresPhysicalIdentityProof =
                requiresPhysicalIdentityProof
        }

        /// A malformed or unreadable snapshot with no usable backup must not
        /// be silently replaced by a fresh, empty session.
        var blockingMessage: String? {
            if problems.contains(.sourceFolderChanged) {
                return "The selected folder changed while Louppe was reading it. "
                    + "Nothing was saved; reconnect the original folder and try again."
            }
            if problems.contains(.sidecarChanged) {
                return "This folder's session file changed while Louppe was reading it. "
                    + "Nothing was saved; open the folder again."
            }
            if problems.contains(where: {
                if case .unsupportedVersion(.sidecar, _) = $0 { return true }
                return false
            }) {
                return "This folder has session data from a different Louppe version. "
                    + "It was left untouched so no saved ratings are lost."
            }
            if problems.contains(where: {
                if case .differentSourceFolder(.sidecar) = $0 { return true }
                return false
            }) {
                return "This folder's session file belongs to a different folder. "
                    + "It was left untouched so ratings are never applied to the wrong photos."
            }
            if problems.contains(where: {
                if case .invalidEntry(.sidecar) = $0 { return true }
                return false
            }) {
                return "This folder's session data does not satisfy Louppe's safety checks. "
                    + "It was left untouched so no saved ratings are replaced by an older backup."
            }
            guard session == nil, !problems.isEmpty else { return nil }
            return "Louppe found session data for this folder but couldn't read it safely. "
                + "The file was left untouched; fix its permissions or restore a valid backup, then try again."
        }

        /// Loading the backup is safe, but the photographer should know why
        /// the folder's own sidecar was not authoritative.
        var recoveryMessage: String? {
            guard session != nil, origin == .backup else { return nil }
            return "Louppe recovered the newest saved ratings from its backup. "
                + "It will repair the folder's session file when it can."
        }
    }

    private enum Candidate {
        case absent
        case valid(SessionFile)
        case problem(ReadProblem)
    }

    private struct CandidateRead {
        let candidate: Candidate
        let revision: SidecarRevision
    }

    private enum SaveGuardError: Error {
        case sourceFolderUnavailable
        case sourceFolderChanged
        case sidecarChanged
    }

    private enum SourceFolderState {
        case matching
        case unavailable
        case changed
    }

    private var latestSequenceByFolder: [String: UInt64] = [:]
    private var revisionByAccessID: [UUID: SidecarRevision] = [:]
    private var backupRevisionByAccessID: [UUID: SidecarRevision] = [:]
    private var snapshotGenerationByAccessID: [UUID: UInt64] = [:]
    /// Set only when this access may have renamed a sidecar immediately before
    /// its source volume disappeared. It permits adopting that one exact
    /// Louppe-owned revision after reconnect without weakening ordinary CAS.
    private var possibleCommittedSidecarRevisionByAccessID:
        [UUID: SidecarRevision] = [:]
    private let backupDirectory: URL
    private let lockDirectory: URL
    private let afterSidecarReadForTesting: (@Sendable () -> Void)?
    private let beforeSaveLockForTesting: (@Sendable () -> Void)?
    private let afterSaveLockAcquiredForTesting: (@Sendable () -> Void)?
    private let afterSidecarReplaceForTesting: (@Sendable () throws -> Void)?
    private let beforeBackupValidationForTesting:
        (@Sendable () throws -> Void)?
    private let afterBackupReplaceForTesting: (@Sendable () throws -> Void)?

    init(
        backupDirectory: URL? = nil,
        afterSidecarReadForTesting: (@Sendable () -> Void)? = nil,
        beforeSaveLockForTesting: (@Sendable () -> Void)? = nil,
        afterSaveLockAcquiredForTesting: (@Sendable () -> Void)? = nil,
        afterSidecarReplaceForTesting: (@Sendable () throws -> Void)? = nil,
        beforeBackupValidationForTesting:
            (@Sendable () throws -> Void)? = nil,
        afterBackupReplaceForTesting: (@Sendable () throws -> Void)? = nil
    ) {
        self.afterSidecarReadForTesting = afterSidecarReadForTesting
        self.beforeSaveLockForTesting = beforeSaveLockForTesting
        self.afterSaveLockAcquiredForTesting =
            afterSaveLockAcquiredForTesting
        self.afterSidecarReplaceForTesting = afterSidecarReplaceForTesting
        self.beforeBackupValidationForTesting =
            beforeBackupValidationForTesting
        self.afterBackupReplaceForTesting = afterBackupReplaceForTesting
        // Advisory locks only need to survive while processes are alive. The
        // per-user temporary root is shared by those processes and remains
        // writable even when Application Support or a custom backup location
        // is unavailable; sidecar safety must not depend on backup permissions.
        self.lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Louppe/SessionLocks", isDirectory: true)
        if let backupDirectory {
            self.backupDirectory = backupDirectory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let root = support.appendingPathComponent(
                "Louppe",
                isDirectory: true
            )
            self.backupDirectory = root.appendingPathComponent(
                "Sessions",
                isDirectory: true
            )
        }
    }

    func save(
        _ session: SessionFile,
        for folder: URL,
        sequence: UInt64,
        access: AccessContext
    ) async -> SaveResult {
        let sourceFolder = folder
        let folderKey = access.folderIdentity.storageKey
        guard sequence > latestSequenceByFolder[folderKey, default: 0] else {
            return .superseded
        }
        guard Self.sessionIsValidForWrite(
            session,
            sourceFolder: sourceFolder
        ) else {
            return .rejectedInvalidSnapshot
        }

        var persistedSession = session
        let assignedGeneration: UInt64?
        if session.version == SessionConstants.currentSchemaVersion {
            let currentGeneration = snapshotGenerationByAccessID[access.id]
                ?? access.initialSnapshotGeneration
            guard currentGeneration < UInt64.max else {
                // Never wrap an ordering counter and make a new snapshot look
                // older than the copy already on disk.
                return .rejectedInvalidSnapshot
            }
            let nextGeneration = currentGeneration + 1
            persistedSession.snapshotGeneration = nextGeneration
            assignedGeneration = nextGeneration
        } else {
            assignedGeneration = nil
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(persistedSession)
        } catch {
            return .failed(SaveFailure(sidecar: .encoding, backup: .encoding))
        }

        let sidecar = Self.sidecarURL(for: sourceFolder)
        let backup = backupSessionURL(for: access.folderIdentity)
        let expectedRevision = revisionByAccessID[access.id]
            ?? access.sidecarRevision
        let expectedBackupRevision = backupRevisionByAccessID[access.id]
            ?? access.backupRevision
        let lock = lockURL(for: access.folderIdentity)

        do {
            return try DurableFileIO.withExclusiveFileLock(
                at: lock,
                beforeLock: { [beforeSaveLockForTesting] in
                    beforeSaveLockForTesting?()
                }
            ) { [afterSaveLockAcquiredForTesting] in
                afterSaveLockAcquiredForTesting?()
                return saveWhileHoldingLock(
                    data,
                    sidecar: sidecar,
                    backup: backup,
                    sourceFolder: sourceFolder,
                    sequence: sequence,
                    folderKey: folderKey,
                    access: access,
                    expectedRevision: expectedRevision,
                    expectedBackupRevision: expectedBackupRevision,
                    assignedGeneration: assignedGeneration
                )
            }
        } catch {
            let reason = Self.failureReason(for: error)
            return .failed(SaveFailure(sidecar: reason, backup: reason))
        }
    }

    /// The cross-process lock covers this complete transaction: both exact
    /// revisions are re-read, the sidecar CAS is replaced, and the fallback's
    /// lineage is either advanced or deliberately left untouched before the
    /// descriptor is unlocked.
    private func saveWhileHoldingLock(
        _ data: Data,
        sidecar: URL,
        backup: URL,
        sourceFolder: URL,
        sequence: UInt64,
        folderKey: String,
        access: AccessContext,
        expectedRevision: SidecarRevision,
        expectedBackupRevision: SidecarRevision,
        assignedGeneration: UInt64?
    ) -> SaveResult {
        var effectiveSidecarRevision = expectedRevision
        switch Self.sourceFolderState(
            expected: access.folderIdentity,
            at: sourceFolder
        ) {
        case .matching:
            break
        case .unavailable:
            return saveToBackupWhileSourceUnavailable(
                data,
                sourceFolder: sourceFolder,
                sequence: sequence,
                folderKey: folderKey,
                access: access,
                expectedSidecarRevision: effectiveSidecarRevision,
                expectedBackupRevision: expectedBackupRevision,
                assignedGeneration: assignedGeneration
            )
        case .changed:
            return .sourceFolderChanged
        }
        let observedSidecarRevision = Self.sidecarRevision(at: sidecar)
        let observedBackupRevision = Self.sidecarRevision(at: backup)
        if Self.revisionsMatch(
            expected: effectiveSidecarRevision,
            current: observedSidecarRevision
        ) {
            if let possible = possibleCommittedSidecarRevisionByAccessID[
                access.id
            ], possible != observedSidecarRevision {
                // Seeing the expected old sidecar proves the uncertain rename
                // did not occupy this live path. Retire the one-shot exception
                // before any later backup-only fallback can preserve it.
                possibleCommittedSidecarRevisionByAccessID.removeValue(
                    forKey: access.id
                )
            }
        } else {
            // A previous save can rename the sidecar successfully, lose the
            // volume before directory sync, then secure its newest snapshot
            // in the tracked backup. Adopt only the exact possible sidecar
            // commit recorded by this same access; an ordinary rollback to an
            // older backup remains an external-change conflict.
            guard observedSidecarRevision
                    == possibleCommittedSidecarRevisionByAccessID[access.id]
            else {
                return .sidecarChanged
            }
            effectiveSidecarRevision = observedSidecarRevision
            revisionByAccessID[access.id] = observedSidecarRevision
        }
        guard Self.backupLineageAllowsSidecarSave(
            expected: expectedBackupRevision,
            current: observedBackupRevision
        ) else {
            return .sidecarChanged
        }

        let desiredRevision = SidecarRevision.content(Self.digest(data))
        let afterSidecarReplaceHook = afterSidecarReplaceForTesting
        do {
            try DurableFileIO.atomicWrite(
                data,
                to: sidecar,
                fullSync: true,
                validateBeforeReplace: {
                    switch Self.sourceFolderState(
                        expected: access.folderIdentity,
                        at: sourceFolder
                    ) {
                    case .matching:
                        break
                    case .unavailable:
                        throw SaveGuardError.sourceFolderUnavailable
                    case .changed:
                        throw SaveGuardError.sourceFolderChanged
                    }
                    guard Self.revisionsMatch(
                        expected: effectiveSidecarRevision,
                        current: Self.sidecarRevision(at: sidecar)
                    ), Self.backupLineageAllowsSidecarSave(
                        expected: expectedBackupRevision,
                        current: Self.sidecarRevision(at: backup)
                    ) else {
                        throw SaveGuardError.sidecarChanged
                    }
                },
                afterReplaceForTesting: {
                    try afterSidecarReplaceHook?()
                }
            )
            let finalBackupRevision = writeBackupBestEffort(
                data,
                for: access.folderIdentity,
                expectedRevision: expectedBackupRevision
            )
            recordSuccessfulSave(
                accessID: access.id,
                sidecarRevision: desiredRevision,
                backupRevision: finalBackupRevision,
                assignedGeneration: assignedGeneration,
                folderKey: folderKey,
                sequence: sequence
            )
            possibleCommittedSidecarRevisionByAccessID.removeValue(
                forKey: access.id
            )
            return .savedToSidecar
        } catch SaveGuardError.sourceFolderUnavailable {
            return saveToBackupWhileSourceUnavailable(
                data,
                sourceFolder: sourceFolder,
                sequence: sequence,
                folderKey: folderKey,
                access: access,
                expectedSidecarRevision: effectiveSidecarRevision,
                expectedBackupRevision: expectedBackupRevision,
                assignedGeneration: assignedGeneration
            )
        } catch SaveGuardError.sourceFolderChanged {
            return .sourceFolderChanged
        } catch SaveGuardError.sidecarChanged {
            return .sidecarChanged
        } catch {
            let sidecarFailure = Self.failureReason(for: error)
            switch Self.sourceFolderState(
                expected: access.folderIdentity,
                at: sourceFolder
            ) {
            case .matching:
                break
            case .unavailable:
                // The sidecar transition can no longer be inspected. Keep
                // its last proven revision and secure the newest snapshot in
                // the identity-owned backup instead.
                return saveToBackupWhileSourceUnavailable(
                    data,
                    sourceFolder: sourceFolder,
                    sequence: sequence,
                    folderKey: folderKey,
                    access: access,
                    expectedSidecarRevision: effectiveSidecarRevision,
                    expectedBackupRevision: expectedBackupRevision,
                    assignedGeneration: assignedGeneration,
                    sidecarMayContainDesiredRevision: true
                )
            case .changed:
                return .sourceFolderChanged
            }
            let observedRevision = Self.sidecarRevision(at: sidecar)
            if observedRevision == desiredRevision {
                // The rename committed and only the trailing directory sync
                // failed. Exact bytes keep this access on the same CAS lineage.
                let finalBackupRevision = writeBackupBestEffort(
                    data,
                    for: access.folderIdentity,
                    expectedRevision: expectedBackupRevision
                )
                recordSuccessfulSave(
                    accessID: access.id,
                    sidecarRevision: desiredRevision,
                    backupRevision: finalBackupRevision,
                    assignedGeneration: assignedGeneration,
                    folderKey: folderKey,
                    sequence: sequence
                )
                possibleCommittedSidecarRevisionByAccessID.removeValue(
                    forKey: access.id
                )
                return .savedToSidecar
            }
            guard Self.revisionsMatch(
                expected: effectiveSidecarRevision,
                current: observedRevision
            ), Self.backupLineageAllowsSidecarSave(
                expected: expectedBackupRevision,
                current: Self.sidecarRevision(at: backup)
            ) else {
                return .sidecarChanged
            }
            guard expectedBackupRevision != .unavailable else {
                return .failed(SaveFailure(
                    sidecar: sidecarFailure,
                    backup: .other
                ))
            }
            do {
                try writeBackup(
                    data,
                    for: access.folderIdentity,
                    expectedRevision: expectedBackupRevision
                )
                recordSuccessfulSave(
                    accessID: access.id,
                    sidecarRevision: effectiveSidecarRevision,
                    backupRevision: desiredRevision,
                    assignedGeneration: assignedGeneration,
                    folderKey: folderKey,
                    sequence: sequence
                )
                return .savedToBackup(sidecarFailure: sidecarFailure)
            } catch SaveGuardError.sidecarChanged {
                return .sidecarChanged
            } catch {
                if recordCommittedBackupIfObserved(
                    desiredRevision: desiredRevision,
                    folderIdentity: access.folderIdentity,
                    accessID: access.id,
                    sidecarRevision: effectiveSidecarRevision,
                    assignedGeneration: assignedGeneration,
                    folderKey: folderKey,
                    sequence: sequence
                ) {
                    // The backup rename committed and only the trailing
                    // directory sync (or its deterministic test boundary)
                    // failed. Adopt those exact bytes so Retry stays on the
                    // same lineage instead of conflicting with our own save.
                    return .savedToBackup(sidecarFailure: sidecarFailure)
                }
                // Do not mark the sequence as persisted. A later request (or
                // an explicit retry of this snapshot) must still be accepted.
                return .failed(SaveFailure(
                    sidecar: sidecarFailure,
                    backup: Self.failureReason(for: error)
                ))
            }
        }
    }

    /// An ejected card cannot receive its sidecar, but its already-captured
    /// stable identity still owns one exact Application Support fallback.
    /// Save there under the same lineage lock without touching or recreating
    /// the absent source path. A replacement that appears before commit turns
    /// this back into a source-folder conflict instead of inheriting ratings.
    private func saveToBackupWhileSourceUnavailable(
        _ data: Data,
        sourceFolder: URL,
        sequence: UInt64,
        folderKey: String,
        access: AccessContext,
        expectedSidecarRevision: SidecarRevision,
        expectedBackupRevision: SidecarRevision,
        assignedGeneration: UInt64?,
        sidecarMayContainDesiredRevision: Bool = false
    ) -> SaveResult {
        guard expectedBackupRevision != .unavailable else {
            return .failed(SaveFailure(
                sidecar: .volumeUnavailable,
                backup: .other
            ))
        }
        let desiredRevision = SidecarRevision.content(Self.digest(data))
        var validatedSidecarRevision = expectedSidecarRevision
        do {
            try writeBackup(
                data,
                for: access.folderIdentity,
                expectedRevision: expectedBackupRevision,
                validateBeforeReplace: {
                    switch Self.sourceFolderState(
                        expected: access.folderIdentity,
                        at: sourceFolder
                    ) {
                    case .unavailable:
                        validatedSidecarRevision = expectedSidecarRevision
                    case .changed:
                        throw SaveGuardError.sourceFolderChanged
                    case .matching:
                        let current = Self.sidecarRevision(
                            at: Self.sidecarURL(for: sourceFolder)
                        )
                        guard Self.revisionsMatch(
                            expected: expectedSidecarRevision,
                            current: current
                        ) || (
                            sidecarMayContainDesiredRevision
                                && current == desiredRevision
                        ) else {
                            throw SaveGuardError.sidecarChanged
                        }
                        validatedSidecarRevision = current
                    }
                }
            )
            recordSuccessfulSave(
                accessID: access.id,
                sidecarRevision: validatedSidecarRevision,
                backupRevision: desiredRevision,
                assignedGeneration: assignedGeneration,
                folderKey: folderKey,
                sequence: sequence
            )
            if sidecarMayContainDesiredRevision,
               validatedSidecarRevision != desiredRevision {
                possibleCommittedSidecarRevisionByAccessID[access.id] =
                    desiredRevision
            } else {
                possibleCommittedSidecarRevisionByAccessID.removeValue(
                    forKey: access.id
                )
            }
            return validatedSidecarRevision == desiredRevision
                ? .savedToSidecar
                : .savedToBackup(sidecarFailure: .volumeUnavailable)
        } catch SaveGuardError.sourceFolderChanged {
            return .sourceFolderChanged
        } catch SaveGuardError.sidecarChanged {
            return .sidecarChanged
        } catch {
            let possibleSidecarRevision = sidecarMayContainDesiredRevision
                    && validatedSidecarRevision != desiredRevision
                ? desiredRevision
                : nil
            if recordCommittedBackupIfObserved(
                desiredRevision: desiredRevision,
                folderIdentity: access.folderIdentity,
                accessID: access.id,
                sidecarRevision: validatedSidecarRevision,
                assignedGeneration: assignedGeneration,
                folderKey: folderKey,
                sequence: sequence,
                possibleSidecarRevision: possibleSidecarRevision
            ) {
                // As above, exact destination bytes prove the rename landed
                // even when its following directory sync reported an error.
                return validatedSidecarRevision == desiredRevision
                    ? .savedToSidecar
                    : .savedToBackup(sidecarFailure: .volumeUnavailable)
            }
            return .failed(SaveFailure(
                sidecar: .volumeUnavailable,
                backup: Self.failureReason(for: error)
            ))
        }
    }

    /// Convenience boundary for tests and one-shot callers. Production
    /// sessions carry the context returned by `read` through every save.
    func save(
        _ session: SessionFile,
        for folder: URL,
        sequence: UInt64
    ) async -> SaveResult {
        guard let identity = try? SourceFolderIdentity.capture(at: folder) else {
            return .sourceFolderChanged
        }
        let sidecar = Self.sidecarURL(for: folder)
        let backup = backupSessionURL(for: identity)
        let access = AccessContext(
            id: UUID(),
            folderIdentity: identity,
            sidecarRevision: Self.sidecarRevision(at: sidecar),
            backupRevision: Self.sidecarRevision(at: backup),
            initialSnapshotGeneration: maximumPersistedGeneration(
                for: identity,
                folder: folder
            )
        )
        revisionByAccessID[access.id] = access.sidecarRevision
        backupRevisionByAccessID[access.id] = access.backupRevision
        snapshotGenerationByAccessID[access.id] =
            access.initialSnapshotGeneration
        return await save(
            session,
            for: folder,
            sequence: sequence,
            access: access
        )
    }

    func read(
        for folder: URL,
        folderIdentity: SourceFolderIdentity
    ) async -> ReadResult {
        let sourceFolder = folder
        guard folderIdentity.matches(folder: sourceFolder) else {
            return ReadResult(
                session: nil,
                origin: nil,
                problems: [.sourceFolderChanged]
            )
        }
        let sidecar = Self.sidecarURL(for: sourceFolder)
        let backup = backupSessionURL(for: folderIdentity)
        let sidecarRead = readCandidate(
            at: sidecar,
            location: .sidecar,
            sourceFolder: sourceFolder
        )
        afterSidecarReadForTesting?()
        let sidecarCandidate = sidecarRead.candidate
        let backupRead = readCandidate(
            at: backup,
            location: .backup,
            sourceFolder: sourceFolder,
            allowsVerifiedRelocation: true
        )
        var backupCandidate = backupRead.candidate
        var usesLegacyPathBackup = false
        // The old backup name was derived only from the mount path, so it can
        // belong to a card that previously occupied this path. Consider it
        // solely when neither current authoritative location exists. Legacy
        // schema 1–3 then requires explicit user confirmation; schema 4 must
        // still prove physical identities in SessionStore.
        if case .absent = sidecarCandidate,
           case .absent = backupCandidate {
            let legacyCandidate = readCandidate(
                at: legacyBackupSessionURL(for: sourceFolder),
                location: .backup,
                sourceFolder: sourceFolder
            ).candidate
            if case .absent = legacyCandidate {
                // Keep the ordinary empty-session path.
            } else {
                backupCandidate = legacyCandidate
                usesLegacyPathBackup = true
            }
        }

        guard folderIdentity.matches(folder: sourceFolder) else {
            return ReadResult(
                session: nil,
                origin: nil,
                problems: [.sourceFolderChanged]
            )
        }
        guard Self.revisionsMatch(
            expected: sidecarRead.revision,
            current: Self.sidecarRevision(at: sidecar)
        ), Self.backupLineageAllowsSidecarSave(
            expected: backupRead.revision,
            current: Self.sidecarRevision(at: backup)
        ) else {
            return ReadResult(
                session: nil,
                origin: nil,
                problems: [.sidecarChanged]
            )
        }

        var valid: [(location: SnapshotLocation, session: SessionFile)] = []
        var problems: [ReadProblem] = []
        for (location, candidate) in [
            (SnapshotLocation.sidecar, sidecarCandidate),
            (SnapshotLocation.backup, backupCandidate),
        ] {
            switch candidate {
            case .absent:
                break
            case .valid(let session):
                valid.append((location, session))
            case .problem(let problem):
                problems.append(problem)
            }
        }

        let newest = valid.max(by: Self.snapshotIsOlder)
        let initialSnapshotGeneration = valid.compactMap {
            $0.session.snapshotGeneration
        }.max() ?? 0
        let access = AccessContext(
            id: UUID(),
            folderIdentity: folderIdentity,
            sidecarRevision: sidecarRead.revision,
            backupRevision: backupRead.revision,
            initialSnapshotGeneration: initialSnapshotGeneration
        )
        revisionByAccessID[access.id] = access.sidecarRevision
        backupRevisionByAccessID[access.id] = access.backupRevision
        snapshotGenerationByAccessID[access.id] =
            access.initialSnapshotGeneration
        return ReadResult(
            session: newest?.session,
            origin: newest?.location,
            problems: problems,
            access: access,
            requiresPhysicalIdentityProof:
                usesLegacyPathBackup && newest?.location == .backup
        )
    }

    func read(for folder: URL) async -> ReadResult {
        guard let identity = try? SourceFolderIdentity.capture(at: folder) else {
            return ReadResult(
                session: nil,
                origin: nil,
                problems: [.sourceFolderChanged]
            )
        }
        return await read(for: folder, folderIdentity: identity)
    }

    private func readCandidate(
        at url: URL,
        location: SnapshotLocation,
        sourceFolder: URL,
        allowsVerifiedRelocation: Bool = false
    ) -> CandidateRead {
        let data: Data
        do {
            data = try DurableFileIO.readRegularFile(
                at: url,
                maximumBytes: Self.maximumSnapshotBytes
            )
        } catch {
            if Self.errorMeansFileIsAbsent(error) {
                return CandidateRead(candidate: .absent, revision: .absent)
            }
            return CandidateRead(
                candidate: .problem(.unreadable(
                    location,
                    Self.failureReason(for: error)
                )),
                revision: .unavailable
            )
        }
        let revision = SidecarRevision.content(Self.digest(data))

        let session: SessionFile
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            session = try decoder.decode(SessionFile.self, from: data)
        } catch {
            return CandidateRead(
                candidate: .problem(.corrupt(location)),
                revision: revision
            )
        }

        guard SessionConstants.supportedSchemaVersions.contains(session.version) else {
            return CandidateRead(
                candidate: .problem(.unsupportedVersion(
                    location,
                    session.version
                )),
                revision: revision
            )
        }
        guard session.version < 3
                || session.fileIDEncoding == .percentEncodedFileSystemPath else {
            return CandidateRead(
                candidate: .problem(.invalidEntry(location)),
                revision: revision
            )
        }
        let recordedFolder = URL(fileURLWithPath: session.sourcePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let requestedFolder = sourceFolder
            .resolvingSymlinksInPath().standardizedFileURL
        // A schema-4 sidecar travels with a renamed/moved folder. Defer that
        // one path mismatch to SessionStore, which has the fresh scan and can
        // require at least one exact physical-file identity match. Backups and
        // legacy path-only sessions never receive this exception.
        let isVerifiedRelocationCandidate =
            (location == .sidecar || allowsVerifiedRelocation)
            && session.version >= 4
        guard recordedFolder.path == requestedFolder.path
                || isVerifiedRelocationCandidate else {
            return CandidateRead(
                candidate: .problem(.differentSourceFolder(location)),
                revision: revision
            )
        }
        guard Self.entriesAreValid(in: session) else {
            return CandidateRead(
                candidate: .problem(.invalidEntry(location)),
                revision: revision
            )
        }
        return CandidateRead(
            candidate: .valid(session),
            revision: revision
        )
    }

    /// A generated snapshot is always newer than a pre-generation snapshot.
    /// When both copies predate generations, preserve the legacy timestamp
    /// ordering. Equal generations represent the same logical checkpoint, so
    /// the folder-owned sidecar wins without consulting a fallible clock.
    private static func snapshotIsOlder(
        _ lhs: (location: SnapshotLocation, session: SessionFile),
        _ rhs: (location: SnapshotLocation, session: SessionFile)
    ) -> Bool {
        switch (lhs.session.snapshotGeneration, rhs.session.snapshotGeneration) {
        case let (left?, right?):
            if left != right { return left < right }
        case (.none, .some):
            return true
        case (.some, .none):
            return false
        case (.none, .none):
            if lhs.session.scannedAt != rhs.session.scannedAt {
                return lhs.session.scannedAt < rhs.session.scannedAt
            }
        }
        // On an exact logical tie, prefer the folder-owned sidecar.
        return lhs.location == .backup && rhs.location == .sidecar
    }

    private func maximumPersistedGeneration(
        for folderIdentity: SourceFolderIdentity,
        folder: URL
    ) -> UInt64 {
        let sourceFolder = folder
        let sidecar = Self.sidecarURL(for: sourceFolder)
        let backup = backupSessionURL(for: folderIdentity)
        let sidecarCandidate = readCandidate(
            at: sidecar,
            location: .sidecar,
            sourceFolder: sourceFolder
        ).candidate
        var backupCandidate = readCandidate(
            at: backup,
            location: .backup,
            sourceFolder: sourceFolder,
            allowsVerifiedRelocation: true
        ).candidate
        if case .absent = sidecarCandidate,
           case .absent = backupCandidate {
            backupCandidate = readCandidate(
                at: legacyBackupSessionURL(for: sourceFolder),
                location: .backup,
                sourceFolder: sourceFolder
            ).candidate
        }
        return [sidecarCandidate, backupCandidate].compactMap { candidate in
            guard case .valid(let session) = candidate else { return nil }
            return session.snapshotGeneration
        }.max() ?? 0
    }

    private static func entriesAreValid(in session: SessionFile) -> Bool {
        // Swift String equality folds canonical Unicode equivalents, but a
        // normalization-sensitive filesystem can store both byte spellings.
        // Physical-file uniqueness therefore follows persisted UTF-8 bytes,
        // including hidden paired files rather than only primary entries.
        let usesExactIDs =
            session.fileIDEncoding == .percentEncodedFileSystemPath
        var physicalFileIDs = Set<Data>()
        for entry in session.entries {
            guard relativeFileIDIsValid(
                    entry.filename,
                    requiresCanonicalPercentEncoding: usesExactIDs
                  ),
                  Rating(rawValue: entry.rating) != nil,
                  session.version >= 5
                    || (entry.stars == nil
                        && entry.starsChangedAt == nil
                        && entry.colorLabel == nil
                        && entry.colorChangedAt == nil),
                  session.version < 4 || entry.pairedFilename == nil,
                  session.version < 4
                    || entry.fileIdentity.map(
                        physicalFileIdentityIsValid
                    ) == true,
                  physicalFileIDs.insert(
                    Data(entry.filename.utf8)
                  ).inserted else {
                return false
            }
            if let paired = entry.pairedFilename {
                guard !paired.contains("/"),
                      relativeFileIDIsValid(
                        paired,
                        requiresCanonicalPercentEncoding: usesExactIDs
                      ) else {
                    return false
                }
                let pairedID: String
                if let separator = entry.filename.lastIndex(of: "/") {
                    pairedID =
                        "\(entry.filename[..<separator])/\(paired)"
                } else {
                    pairedID = paired
                }
                guard physicalFileIDs.insert(
                    Data(pairedID.utf8)
                ).inserted else {
                    return false
                }
            }
        }
        return true
    }

    private static func physicalFileIdentityIsValid(
        _ identity: FileOperationJournal.FileIdentity
    ) -> Bool {
        guard (identity.volumeRootPath as NSString).isAbsolutePath,
              identity.volumeUUIDString?.isEmpty != true,
              let logicalSize = identity.logicalSize,
              logicalSize >= 0,
              let modificationTime = identity.modificationTime,
              let statusChangeTime = identity.statusChangeTime,
              let birthTime = identity.birthTime else {
            return false
        }
        return [modificationTime, statusChangeTime, birthTime].allSatisfy {
            (0..<1_000_000_000).contains($0.nanoseconds)
        }
    }

    private static func relativeFileIDIsValid(
        _ fileID: String,
        requiresCanonicalPercentEncoding: Bool
    ) -> Bool {
        guard !fileID.isEmpty,
              !fileID.hasPrefix("/"),
              !fileID.hasSuffix("/"),
              !fileID.contains("//") else {
            return false
        }
        if requiresCanonicalPercentEncoding {
            return exactFileIDIsCanonical(fileID)
        }
        let components = (fileID as NSString).pathComponents
        return !components.contains(".") && !components.contains("..")
    }

    /// Schema-3 IDs are the exact ASCII output of
    /// `URL.path(percentEncoded: true)`, relative to the opened folder.
    /// Decode and rebuild that filesystem representation so malformed escapes,
    /// direct Unicode, encoded separators, and alternate spellings cannot
    /// identify the same physical file under different keys.
    private static func exactFileIDIsCanonical(_ fileID: String) -> Bool {
        let encoded = Array(fileID.utf8)
        guard encoded.allSatisfy({ $0 < 0x80 }) else { return false }

        var raw: [UInt8] = []
        raw.reserveCapacity(encoded.count)
        var index = 0
        while index < encoded.count {
            let byte = encoded[index]
            if byte == 0x25 {
                guard index + 2 < encoded.count,
                      let high = hexadecimalNibble(encoded[index + 1]),
                      let low = hexadecimalNibble(encoded[index + 2]) else {
                    return false
                }
                raw.append((high << 4) | low)
                index += 3
            } else {
                raw.append(byte)
                index += 1
            }
        }
        guard !raw.contains(0) else { return false }
        let components = raw.split(
            separator: 0x2F,
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({
            !$0.isEmpty
                && !($0.count == 1 && $0.first == 0x2E)
                && !($0.count == 2
                    && $0.first == 0x2E
                    && $0.last == 0x2E)
        }) else {
            return false
        }

        var representation = [Int8(bitPattern: 0x2F)]
        representation.append(
            contentsOf: raw.map(Int8.init(bitPattern:))
        )
        representation.append(0)
        let canonical = representation.withUnsafeBufferPointer { buffer in
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: false,
                relativeTo: nil
            ).path(percentEncoded: true)
        }
        guard canonical.hasPrefix("/") else { return false }
        return Data(canonical.dropFirst().utf8) == Data(fileID.utf8)
    }

    private static func hexadecimalNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    /// Keep the writer and reader on one contract. Rejecting an internally
    /// inconsistent snapshot before encoding preserves both the folder
    /// sidecar and its last-known-good backup.
    private static func sessionIsValidForWrite(
        _ session: SessionFile,
        sourceFolder: URL
    ) -> Bool {
        guard SessionConstants.supportedSchemaVersions.contains(session.version),
              session.version < 3
                || session.fileIDEncoding == .percentEncodedFileSystemPath,
              entriesAreValid(in: session) else {
            return false
        }
        let recordedFolder = URL(fileURLWithPath: session.sourcePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let requestedFolder = sourceFolder
            .resolvingSymlinksInPath().standardizedFileURL
        return recordedFolder.path == requestedFolder.path
    }

    private func recordSuccessfulSave(
        accessID: UUID,
        sidecarRevision: SidecarRevision,
        backupRevision: SidecarRevision,
        assignedGeneration: UInt64?,
        folderKey: String,
        sequence: UInt64
    ) {
        revisionByAccessID[accessID] = sidecarRevision
        backupRevisionByAccessID[accessID] = backupRevision
        if let assignedGeneration {
            snapshotGenerationByAccessID[accessID] = assignedGeneration
        }
        latestSequenceByFolder[folderKey] = sequence
    }

    /// `atomicWrite` can throw after its rename has committed. Exact
    /// destination bytes are sufficient to adopt that commit and keep the
    /// access's CAS/generation lineage usable for the next save.
    private func recordCommittedBackupIfObserved(
        desiredRevision: SidecarRevision,
        folderIdentity: SourceFolderIdentity,
        accessID: UUID,
        sidecarRevision: SidecarRevision,
        assignedGeneration: UInt64?,
        folderKey: String,
        sequence: UInt64,
        possibleSidecarRevision: SidecarRevision? = nil
    ) -> Bool {
        let backup = backupSessionURL(for: folderIdentity)
        guard Self.sidecarRevision(at: backup) == desiredRevision else {
            return false
        }
        recordSuccessfulSave(
            accessID: accessID,
            sidecarRevision: sidecarRevision,
            backupRevision: desiredRevision,
            assignedGeneration: assignedGeneration,
            folderKey: folderKey,
            sequence: sequence
        )
        if let possibleSidecarRevision {
            possibleCommittedSidecarRevisionByAccessID[accessID] =
                possibleSidecarRevision
        }
        return true
    }

    /// Updating the fallback is best-effort after a durable sidecar commit.
    /// Reconcile an error from exact bytes because `atomicWrite` can report a
    /// trailing directory-sync failure after its rename already committed.
    private func writeBackupBestEffort(
        _ data: Data,
        for folderIdentity: SourceFolderIdentity,
        expectedRevision: SidecarRevision
    ) -> SidecarRevision {
        // An unreadable fallback cannot participate in exact CAS. Preserve it
        // byte-for-byte; the authoritative sidecar may still save safely.
        guard expectedRevision != .unavailable else { return .unavailable }
        let backup = backupSessionURL(for: folderIdentity)
        let desiredRevision = SidecarRevision.content(Self.digest(data))
        do {
            try writeBackup(
                data,
                for: folderIdentity,
                expectedRevision: expectedRevision
            )
            return desiredRevision
        } catch {
            let observed = Self.sidecarRevision(at: backup)
            if observed == desiredRevision || observed == expectedRevision {
                return observed
            }
            // An uncoordinated writer changed the fallback. Do not adopt that
            // lineage silently; the next save must fail closed until a reread.
            return .unavailable
        }
    }

    private func writeBackup(
        _ data: Data,
        for folderIdentity: SourceFolderIdentity,
        expectedRevision: SidecarRevision,
        validateBeforeReplace: () throws -> Void = {}
    ) throws {
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        let backup = backupSessionURL(for: folderIdentity)
        let beforeValidationForTesting = beforeBackupValidationForTesting
        let afterReplaceForTesting = afterBackupReplaceForTesting
        try DurableFileIO.atomicWrite(
            data,
            to: backup,
            fullSync: true,
            validateBeforeReplace: {
                try beforeValidationForTesting?()
                try validateBeforeReplace()
                guard Self.revisionsMatch(
                    expected: expectedRevision,
                    current: Self.sidecarRevision(at: backup)
                ) else {
                    throw SaveGuardError.sidecarChanged
                }
            },
            afterReplaceForTesting: {
                try afterReplaceForTesting?()
            }
        )
    }

    /// Distinguishes a genuinely absent/ejected path from a different folder
    /// now occupying the same name. Only absence may use the identity-keyed
    /// backup without a live identity check.
    private static func sourceFolderState(
        expected: SourceFolderIdentity,
        at folder: URL
    ) -> SourceFolderState {
        // Device-number remapping is safe only after the complete folder can
        // be captured and its UUID/folder identity proves this is the same
        // reconnected volume. If the leaf is absent or unreadable, repeat the
        // path decision with strict devices so a different blank card cannot
        // masquerade as an ejected original merely because both roots use a
        // common inode such as 2.
        if let current = try? SourceFolderIdentity.capture(at: folder) {
            guard current == expected else { return .changed }
            return expected.pathState(
                at: folder,
                allowSourceVolumeDeviceRemapping: true
            ) == .matching ? .matching : .changed
        }
        switch expected.pathState(
            at: folder,
            allowSourceVolumeDeviceRemapping: false
        ) {
        case .unavailable:
            return .unavailable
        case .changed, .matching:
            // Every exact path entry either changed or still exists with its
            // original strict identity. In both cases, inability to capture
            // the final directory is ambiguity rather than proof of eject.
            return .changed
        }
    }

    static func sidecarURL(for folder: URL) -> URL {
        folder.appendingPathComponent(SessionConstants.sidecarName)
    }

    private func backupSessionURL(
        for folderIdentity: SourceFolderIdentity
    ) -> URL {
        backupDirectory.appendingPathComponent(
            "folder-\(folderIdentity.storageKey).json"
        )
    }

    private func lockURL(for folderIdentity: SourceFolderIdentity) -> URL {
        lockDirectory.appendingPathComponent(
            "folder-\(folderIdentity.storageKey).lock"
        )
    }

    /// Read-only compatibility with releases that keyed backups by the
    /// standardized path. New writes always use `SourceFolderIdentity`.
    private func legacyBackupSessionURL(for folder: URL) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in folder.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return backupDirectory.appendingPathComponent(
            String(format: "%016llx.json", hash)
        )
    }

    private static func sidecarRevision(at url: URL) -> SidecarRevision {
        do {
            let data = try DurableFileIO.readRegularFile(
                at: url,
                maximumBytes: maximumSnapshotBytes
            )
            return .content(digest(data))
        } catch {
            if errorMeansFileIsAbsent(error) { return .absent }
            return .unavailable
        }
    }

    private static func errorMeansFileIsAbsent(_ error: Error) -> Bool {
        if case DurableFileIO.IOError.system(_, _, let code) = error {
            return code == ENOENT
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
        }
        if nsError.domain == NSCocoaErrorDomain {
            return CocoaError.Code(rawValue: nsError.code) == .fileNoSuchFile
                || CocoaError.Code(rawValue: nsError.code)
                    == .fileReadNoSuchFile
        }
        return false
    }

    private static func revisionsMatch(
        expected: SidecarRevision,
        current: SidecarRevision
    ) -> Bool {
        switch (expected, current) {
        case (.absent, .absent):
            return true
        case (.content(let lhs), .content(let rhs)):
            return lhs == rhs
        case (.unavailable, _), (_, .unavailable),
             (.absent, .content), (.content, .absent):
            return false
        }
    }

    private static func backupLineageAllowsSidecarSave(
        expected: SidecarRevision,
        current: SidecarRevision
    ) -> Bool {
        if expected == .unavailable {
            // The caller must not write the unknown fallback in this state.
            // A locked reread may permit an exact sidecar commit only while
            // that fallback remains unavailable. Becoming absent or readable
            // proves the lineage changed; accepting it could let a stale
            // generation tie and outrank a newer backup-only save.
            return current == .unavailable
        }
        return revisionsMatch(expected: expected, current: current)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failureReason(for error: Error) -> FailureReason {
        if case DurableFileIO.IOError.system(
            operation: "wait for persistence lock",
            path: _,
            code: _
        ) = error {
            return .busy
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                return .permissionDenied
            case .fileWriteOutOfSpace:
                return .outOfSpace
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return .volumeUnavailable
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EACCES), Int(EPERM), Int(EROFS):
                return .permissionDenied
            case Int(ENOSPC):
                return .outOfSpace
            case Int(ENOENT), Int(ENODEV):
                return .volumeUnavailable
            default:
                break
            }
        }
        return .other
    }
}
