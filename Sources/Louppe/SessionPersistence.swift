import Foundation

/// Serializes sidecar reads and writes away from the main actor.
///
/// Save requests carry a monotonically increasing sequence number. This makes
/// fire-and-forget saves safe: if task scheduling delivers an older snapshot
/// late, it cannot overwrite a newer snapshot for the same folder.
actor SessionPersistence {
    enum SnapshotLocation: String, Sendable {
        case sidecar
        case backup
    }

    enum FailureReason: String, Sendable, Equatable {
        case permissionDenied
        case outOfSpace
        case volumeUnavailable
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
        /// A newer sequence for this folder already reached stable storage.
        case superseded

        var canDiscardInMemoryState: Bool {
            switch self {
            case .savedToSidecar, .savedToBackup, .superseded:
                return true
            case .failed:
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
    }

    struct ReadResult: Sendable {
        let session: SessionFile?
        let origin: SnapshotLocation?
        let problems: [ReadProblem]

        /// A malformed or unreadable snapshot with no usable backup must not
        /// be silently replaced by a fresh, empty session.
        var blockingMessage: String? {
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

    private var latestSequenceByFolder: [String: UInt64] = [:]
    private let backupDirectory: URL

    init(backupDirectory: URL? = nil) {
        if let backupDirectory {
            self.backupDirectory = backupDirectory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.backupDirectory = support.appendingPathComponent(
                "Louppe/Sessions",
                isDirectory: true
            )
        }
    }

    func save(_ session: SessionFile, for folder: URL, sequence: UInt64) -> SaveResult {
        let standardizedFolder = folder.standardizedFileURL
        let folderKey = standardizedFolder.path
        guard sequence > latestSequenceByFolder[folderKey, default: 0] else {
            return .superseded
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(session)
        } catch {
            return .failed(SaveFailure(sidecar: .encoding, backup: .encoding))
        }

        let sidecar = standardizedFolder.appendingPathComponent(
            SessionConstants.sidecarName
        )
        do {
            try data.write(to: sidecar, options: .atomic)
            latestSequenceByFolder[folderKey] = sequence
            // Keep the fallback current as a last-known-good snapshot. Failure
            // here does not make the successful folder sidecar unsafe.
            try? writeBackup(data, for: standardizedFolder)
            return .savedToSidecar
        } catch {
            let sidecarFailure = Self.failureReason(for: error)
            do {
                try writeBackup(data, for: standardizedFolder)
                latestSequenceByFolder[folderKey] = sequence
                return .savedToBackup(sidecarFailure: sidecarFailure)
            } catch {
                // Do not mark the sequence as persisted. A later request (or
                // an explicit retry of this snapshot) must still be accepted.
                return .failed(SaveFailure(
                    sidecar: sidecarFailure,
                    backup: Self.failureReason(for: error)
                ))
            }
        }
    }

    func read(for folder: URL) -> ReadResult {
        let standardizedFolder = folder.standardizedFileURL
        let sidecar = standardizedFolder.appendingPathComponent(
            SessionConstants.sidecarName
        )
        let backup = backupSessionURL(for: standardizedFolder)
        let sidecarCandidate = readCandidate(
            at: sidecar,
            location: .sidecar,
            sourceFolder: standardizedFolder
        )
        let backupCandidate = readCandidate(
            at: backup,
            location: .backup,
            sourceFolder: standardizedFolder
        )

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

        let newest = valid.max { lhs, rhs in
            if lhs.session.scannedAt == rhs.session.scannedAt {
                // On an exact tie, prefer the folder-owned sidecar.
                return lhs.location == .backup && rhs.location == .sidecar
            }
            return lhs.session.scannedAt < rhs.session.scannedAt
        }
        return ReadResult(
            session: newest?.session,
            origin: newest?.location,
            problems: problems
        )
    }

    private func readCandidate(
        at url: URL,
        location: SnapshotLocation,
        sourceFolder: URL
    ) -> Candidate {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .problem(.unreadable(location, Self.failureReason(for: error)))
        }

        let session: SessionFile
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            session = try decoder.decode(SessionFile.self, from: data)
        } catch {
            return .problem(.corrupt(location))
        }

        guard session.version == 1 else {
            return .problem(.unsupportedVersion(location, session.version))
        }
        let recordedFolder = URL(fileURLWithPath: session.sourcePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let requestedFolder = sourceFolder
            .resolvingSymlinksInPath().standardizedFileURL
        guard recordedFolder.path == requestedFolder.path else {
            return .problem(.differentSourceFolder(location))
        }
        guard Self.entriesAreValid(session.entries) else {
            return .problem(.invalidEntry(location))
        }
        return .valid(session)
    }

    private static func entriesAreValid(_ entries: [SessionEntry]) -> Bool {
        var filenames = Set<String>()
        for entry in entries {
            let components = (entry.filename as NSString).pathComponents
            guard !entry.filename.isEmpty,
                  !entry.filename.hasPrefix("/"),
                  !components.contains("."),
                  !components.contains(".."),
                  Rating(rawValue: entry.rating) != nil,
                  filenames.insert(entry.filename).inserted else {
                return false
            }
            if let paired = entry.pairedFilename {
                guard !paired.isEmpty,
                      paired != ".",
                      paired != "..",
                      (paired as NSString).lastPathComponent == paired else {
                    return false
                }
            }
        }
        return true
    }

    private func writeBackup(_ data: Data, for folder: URL) throws {
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: backupSessionURL(for: folder), options: .atomic)
    }

    private func backupSessionURL(for folder: URL) -> URL {
        var hash: UInt64 = 14695981039346656037
        for byte in folder.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return backupDirectory.appendingPathComponent(
            String(format: "%016llx.json", hash)
        )
    }

    private static func failureReason(for error: Error) -> FailureReason {
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
