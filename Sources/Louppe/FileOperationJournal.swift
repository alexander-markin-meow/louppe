import Darwin
import Foundation

/// Durable checkpoints for every filesystem operation that can leave a RAW+
/// JPEG pair split if the process dies between members.
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
        /// The file whose stable volume/inode identity should be captured.
        /// Trash restore moves from `destination` back to `source`, so its
        /// identity URL differs from the desired source-state URL.
        let identityURL: URL

        init(
            itemID: String,
            source: URL,
            destination: URL?,
            identityURL: URL? = nil
        ) {
            self.itemID = itemID
            self.source = source
            self.destination = destination
            self.identityURL = identityURL ?? source
        }
    }

    struct Token: Codable, Equatable, Sendable {
        let operationID: String
        let directory: URL
    }

    struct FileIdentity: Codable, Equatable, Sendable {
        let volumeRootPath: String
        let systemNumber: UInt64
        let fileNumber: UInt64
    }

    struct PlannedFile: Codable, Equatable, Sendable {
        let itemID: String
        let sourcePath: String
        let destinationPath: String?
        let temporaryPath: String?
        let identity: FileIdentity
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
        /// Identity of the staged/completed file at the time this checkpoint
        /// was written. Recovery refuses to touch a same-named replacement.
        let resolvedIdentity: FileIdentity?
        let updatedAt: Date
    }

    final class Writer {
        let token: Token
        let plan: Plan
        private let stepsDirectory: URL

        fileprivate init(token: Token, plan: Plan) {
            self.token = token
            self.plan = plan
            stepsDirectory = token.directory.appendingPathComponent(
                "steps",
                isDirectory: true
            )
        }

        func temporaryURL(at index: Int) -> URL? {
            guard plan.files.indices.contains(index),
                  let path = plan.files[index].temporaryPath else { return nil }
            return URL(fileURLWithPath: path)
        }

        func mark(
            _ state: StepState,
            fileAt index: Int,
            resolvedDestination: URL? = nil,
            identityAt identityURL: URL? = nil
        ) throws {
            guard plan.files.indices.contains(index) else {
                throw JournalError.invalidFileIndex
            }
            let record = StateRecord(
                state: state,
                resolvedDestinationPath: resolvedDestination?.standardizedFileURL.path,
                resolvedIdentity: try identityURL.map(FileOperationJournal.fileIdentity),
                updatedAt: Date()
            )
            try Self.encoder.encode(record).write(
                to: stateURL(at: index),
                options: .atomic
            )
        }

        /// A committed marker means the worker completed and its coordinator
        /// may safely keep the resulting filesystem state. If the process dies
        /// before the journal directory is removed, launch recovery only
        /// removes the stale journal instead of undoing a completed operation.
        func markCommitted() throws {
            try Data("committed\n".utf8).write(
                to: token.directory.appendingPathComponent("committed"),
                options: .atomic
            )
        }

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
        var removedPartialCopies = 0
        var unresolvedFiles = 0
        var unavailableVolumes: [String] = []
        var details: [String] = []

        var foundOperations: Int { discoveredOperations }

        var hasUnresolvedFiles: Bool { unresolvedFiles > 0 }
    }

    enum JournalError: LocalizedError {
        case invalidFileIndex
        case missingFileIdentity(URL)
        case corruptPlan(URL)

        var errorDescription: String? {
            switch self {
            case .invalidFileIndex:
                return "The operation journal contains an invalid file index."
            case .missingFileIdentity(let url):
                return "Louppe couldn't identify \(url.lastPathComponent) before starting the file operation."
            case .corruptPlan:
                return "An interrupted-operation journal is unreadable."
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
                let destination = seed.destination?.standardizedFileURL
                let temporary: URL?
                switch kind {
                case .exportCopy, .exportMove:
                    guard let destination else { throw JournalError.corruptPlan(creating) }
                    temporary = destination.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".louppe-\(operationID)-\(index).partial"
                        )
                case .moveToTrash, .restoreFromTrash:
                    temporary = nil
                }
                return PlannedFile(
                    itemID: seed.itemID,
                    sourcePath: seed.source.standardizedFileURL.path,
                    destinationPath: destination?.path,
                    temporaryPath: temporary?.standardizedFileURL.path,
                    identity: try fileIdentity(at: seed.identityURL)
                )
            }
            let plan = Plan(
                version: 1,
                operationID: operationID,
                kind: kind,
                createdAt: Date(),
                files: files
            )
            try encoder.encode(plan).write(
                to: creating.appendingPathComponent("plan.json"),
                options: .atomic
            )
            // The completed plan becomes discoverable in one rename.
            try fm.moveItem(at: creating, to: active)
            return Writer(
                token: Token(operationID: operationID, directory: active),
                plan: plan
            )
        } catch {
            try? fm.removeItem(at: creating)
            throw error
        }
    }

    static func remove(_ token: Token) throws {
        try FileManager.default.removeItem(at: token.directory)
    }

    /// Seals an operation whose filesystem state is consistent. A committed
    /// marker makes a later stale journal harmless; direct removal is the
    /// fallback when the marker itself cannot be written.
    @discardableResult
    static func finalize(
        _ writer: Writer,
        operationIsConsistent: Bool
    ) -> Bool {
        guard operationIsConsistent else { return true }
        do {
            try writer.markCommitted()
            // A committed journal is safe even if cleanup fails. Recovery
            // preserves the operation's result and removes only the journal.
            try? remove(writer.token)
            return true
        } catch {
            do {
                try remove(writer.token)
                return true
            } catch {
                return false
            }
        }
    }

    static func hasPendingOperations(directory rootOverride: URL? = nil) -> Bool {
        let root = rootOverride ?? defaultDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.pathExtension == "operation" }
    }

    /// Restores the conservative source-folder state for every *active*
    /// operation. A committed operation keeps its completed result and only
    /// loses the stale journal. Existing files are never overwritten.
    static func recoverPendingOperations(
        directory rootOverride: URL? = nil
    ) -> RecoveryReport {
        let root = rootOverride ?? defaultDirectory
        let fm = FileManager()
        var report = RecoveryReport()
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return report }

        // A .creating directory was never activated, so no corresponding file
        // operation was allowed to start.
        for url in contents where url.pathExtension == "creating" {
            try? fm.removeItem(at: url)
        }

        for operationURL in contents
            .filter({ $0.pathExtension == "operation" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            report.discoveredOperations += 1
            do {
                let plan = try decodePlan(at: operationURL)
                if fm.fileExists(
                    atPath: operationURL.appendingPathComponent("committed").path
                ) {
                    try fm.removeItem(at: operationURL)
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
                            operationID: plan.operationID
                        )
                        report.restoredFiles += result.restoredFiles
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
                    try fm.removeItem(at: operationURL)
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
        var removedCopies = 0
    }

    private static func recover(
        _ file: PlannedFile,
        kind: Kind,
        state: StateRecord?,
        operationID: String
    ) throws -> RecoveredFileCounts {
        switch kind {
        case .exportCopy:
            return try recoverCopy(file, state: state, operationID: operationID)
        case .exportMove:
            return try recoverMove(file, state: state, operationID: operationID)
        case .moveToTrash:
            return try recoverTrash(file, state: state)
        case .restoreFromTrash:
            return try recoverTrashRestore(file)
        }
    }

    private static func recoverCopy(
        _ file: PlannedFile,
        state: StateRecord?,
        operationID: String
    ) throws -> RecoveredFileCounts {
        let fm = FileManager()
        var counts = RecoveredFileCounts()
        if let temporaryPath = file.temporaryPath {
            let temporary = URL(fileURLWithPath: temporaryPath)
            try validateTemporary(temporary, operationID: operationID)
            if fm.fileExists(atPath: temporary.path) {
                if state?.state == .staged,
                   let identity = state?.resolvedIdentity {
                    try requireIdentity(identity, at: temporary)
                }
                try fm.removeItem(at: temporary)
                counts.removedCopies += 1
            }
        }
        if state?.state == .staged || state?.state == .completed,
           let destinationPath = file.destinationPath {
            let destination = URL(fileURLWithPath: destinationPath)
            if fm.fileExists(atPath: destination.path) {
                guard let identity = state?.resolvedIdentity else {
                    throw RecoveryError.unverifiedOwnedFile(destination)
                }
                try requireIdentity(identity, at: destination)
                try fm.removeItem(at: destination)
                counts.removedCopies += 1
            }
        }
        return counts
    }

    private static func recoverMove(
        _ file: PlannedFile,
        state: StateRecord?,
        operationID: String
    ) throws -> RecoveredFileCounts {
        let fm = FileManager()
        let source = URL(fileURLWithPath: file.sourcePath)
        let temporary = file.temporaryPath.map(URL.init(fileURLWithPath:))
        if let temporary {
            try validateTemporary(temporary, operationID: operationID)
        }
        let destination = file.destinationPath.map(URL.init(fileURLWithPath:))
        let sourceExists = fm.fileExists(atPath: source.path)
        let temporaryExists = temporary.map { fm.fileExists(atPath: $0.path) } ?? false
        let destinationIsOwned = state?.state == .staged || state?.state == .completed
        let destinationExists = destination.map { fm.fileExists(atPath: $0.path) } ?? false

        if sourceExists {
            if temporaryExists, let temporary {
                try requireIdentity(file.identity, at: temporary)
                try fm.removeItem(at: temporary)
            }
            if destinationIsOwned, destinationExists, let destination {
                try requireIdentity(file.identity, at: destination)
                try fm.removeItem(at: destination)
            }
            return RecoveredFileCounts()
        }

        let ownedLocation: URL?
        if temporaryExists {
            ownedLocation = temporary
        } else if destinationIsOwned, destinationExists {
            ownedLocation = destination
        } else {
            ownedLocation = nil
        }
        guard let ownedLocation else {
            throw RecoveryError.missingMovedFile(source)
        }
        try requireIdentity(file.identity, at: ownedLocation)
        try restoreWithoutOverwrite(from: ownedLocation, to: source)
        return RecoveredFileCounts(restoredFiles: 1)
    }

    private static func recoverTrash(
        _ file: PlannedFile,
        state: StateRecord?
    ) throws -> RecoveredFileCounts {
        let fm = FileManager()
        let source = URL(fileURLWithPath: file.sourcePath)
        if fm.fileExists(atPath: source.path) {
            if let path = state?.resolvedDestinationPath,
               fm.fileExists(atPath: path) {
                throw RecoveryError.bothLocationsExist(source)
            }
            return RecoveredFileCounts()
        }

        if let path = state?.resolvedDestinationPath {
            let trash = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: trash.path) else {
                throw RecoveryError.missingTrashedFile(source)
            }
            guard let identity = state?.resolvedIdentity else {
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
        _ file: PlannedFile
    ) throws -> RecoveredFileCounts {
        let fm = FileManager()
        let source = URL(fileURLWithPath: file.sourcePath)
        guard let destinationPath = file.destinationPath else {
            throw RecoveryError.missingTrashedFile(source)
        }
        let trash = URL(fileURLWithPath: destinationPath)
        let sourceExists = fm.fileExists(atPath: source.path)
        let trashExists = fm.fileExists(atPath: trash.path)
        if sourceExists && trashExists {
            throw RecoveryError.bothLocationsExist(source)
        }
        if sourceExists {
            try requireIdentity(file.identity, at: source)
            return RecoveredFileCounts()
        }
        guard trashExists else { throw RecoveryError.missingTrashedFile(source) }
        try requireIdentity(file.identity, at: trash)
        try restoreWithoutOverwrite(from: trash, to: source)
        return RecoveredFileCounts(restoredFiles: 1)
    }

    private static func restoreWithoutOverwrite(from: URL, to: URL) throws {
        let fm = FileManager()
        guard !fm.fileExists(atPath: to.path) else {
            throw RecoveryError.refusesOverwrite(to)
        }
        try fm.createDirectory(
            at: to.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: from, to: to)
    }

    private static func validateTemporary(
        _ url: URL,
        operationID: String
    ) throws {
        guard url.lastPathComponent.hasPrefix(".louppe-\(operationID)-"),
              url.lastPathComponent.hasSuffix(".partial") else {
            throw RecoveryError.unsafeTemporaryPath(url)
        }
    }

    private static func requireIdentity(
        _ expected: FileIdentity,
        at url: URL
    ) throws {
        guard try fileIdentity(at: url) == expected else {
            throw RecoveryError.unverifiedOwnedFile(url)
        }
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
                if let candidateIdentity = try? fileIdentity(at: candidate),
                   candidateIdentity.systemNumber == identity.systemNumber,
                   candidateIdentity.fileNumber == identity.fileNumber {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func fileIdentity(at url: URL) throws -> FileIdentity {
        let fm = FileManager()
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let system = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber,
              let volume = volumeRoot(containing: url, fileManager: fm) else {
            throw JournalError.missingFileIdentity(url)
        }
        return FileIdentity(
            volumeRootPath: volume.standardizedFileURL.path,
            systemNumber: system.uint64Value,
            fileNumber: file.uint64Value
        )
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

    private static func decodePlan(at operationURL: URL) throws -> Plan {
        let planURL = operationURL.appendingPathComponent("plan.json")
        do {
            let plan = try decoder.decode(Plan.self, from: Data(contentsOf: planURL))
            guard plan.version == 1,
                  operationURL.lastPathComponent == "\(plan.operationID).operation" else {
                throw JournalError.corruptPlan(planURL)
            }
            return plan
        } catch {
            throw JournalError.corruptPlan(planURL)
        }
    }

    private static func readState(
        at operationURL: URL,
        index: Int
    ) -> StateRecord? {
        let url = operationURL
            .appendingPathComponent("steps", isDirectory: true)
            .appendingPathComponent(String(format: "%08d.json", index))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(StateRecord.self, from: data)
    }

    private enum RecoveryError: LocalizedError {
        case missingMovedFile(URL)
        case missingTrashedFile(URL)
        case bothLocationsExist(URL)
        case refusesOverwrite(URL)
        case unsafeTemporaryPath(URL)
        case unverifiedOwnedFile(URL)

        var errorDescription: String? {
            switch self {
            case .missingMovedFile(let source):
                return "The interrupted move couldn't locate \(source.lastPathComponent)."
            case .missingTrashedFile(let source):
                return "The interrupted Trash operation couldn't locate \(source.lastPathComponent)."
            case .bothLocationsExist(let source):
                return "\(source.lastPathComponent) exists in both locations; Louppe left both untouched."
            case .refusesOverwrite(let url):
                return "Recovery refused to overwrite \(url.lastPathComponent)."
            case .unsafeTemporaryPath:
                return "Recovery found an invalid temporary path and left it untouched."
            case .unverifiedOwnedFile(let url):
                return "Recovery couldn't verify that \(url.lastPathComponent) belongs to the interrupted operation, so it left the file untouched."
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
}
