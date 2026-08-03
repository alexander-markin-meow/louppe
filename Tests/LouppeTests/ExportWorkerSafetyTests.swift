import Darwin
import Foundation
import XCTest
@testable import Louppe

final class ExportWorkerSafetyTests: XCTestCase {
    func testCopyRetriesOnceAfterTransientSourceIOFailure() throws {
        let root = try makeTemporaryDirectory(named: "CopyTransientRetry")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = try makeDirectory(named: "Source", in: root)
        let destination = try makeDirectory(named: "Destination", in: root)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        let source = sourceFolder.appendingPathComponent("SOURCE.JPG")
        let contents = Data("copy resumes after a remount-sized interruption".utf8)
        try contents.write(to: source)
        let item = makeItem(id: "SOURCE.JPG", primaryURL: source)
        let copier = FailFirstFileCopier()

        let result = ExportWorker.copy(
            [item],
            to: destination,
            journalDirectory: journals,
            fileCopier: copier.copy
        ) { _, _ in }

        XCTAssertEqual(copier.attempts, 2)
        XCTAssertEqual(result.copiedFiles, 1)
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("SOURCE.JPG")),
            contents
        )
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testCopyRecordsAndRemovesItsOwnPartialFile() throws {
        let root = try makeTemporaryDirectory(named: "CopyPartialNoRetry")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = try makeDirectory(named: "Source", in: root)
        let destination = try makeDirectory(named: "Destination", in: root)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        let source = sourceFolder.appendingPathComponent("SOURCE.JPG")
        try Data("complete source".utf8).write(to: source)
        let item = makeItem(id: "SOURCE.JPG", primaryURL: source)
        let copier = PartialFailingFileCopier()

        let result = ExportWorker.copy(
            [item],
            to: destination,
            journalDirectory: journals,
            fileCopier: copier.copy
        ) { _, _ in }

        XCTAssertEqual(copier.attempts, 1)
        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.journalFailure)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertEqual(try Data(contentsOf: source), Data("complete source".utf8))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testCopyCompletesAfterVerifiedSourceDriveBecomesUnavailable() throws {
        let root = try makeTemporaryDirectory(named: "CopySourceDisconnect")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = try makeDirectory(named: "Source", in: root)
        let destination = try makeDirectory(named: "Destination", in: root)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        let source = sourceFolder.appendingPathComponent("SOURCE.JPG")
        let disconnectedSource = root.appendingPathComponent("OFFLINE-SOURCE.JPG")
        let contents = Data("verified copy survives source disconnect".utf8)
        try contents.write(to: source)
        let item = makeItem(id: "SOURCE.JPG", primaryURL: source)
        var disconnectError: Error?

        let result = ExportWorker.copy(
            [item],
            to: destination,
            journalDirectory: journals,
            afterStagedFile: { _ in
                do {
                    try FileManager.default.moveItem(
                        at: source,
                        to: disconnectedSource
                    )
                } catch {
                    disconnectError = error
                }
            }
        ) { _, _ in }
        if let disconnectError { throw disconnectError }

        XCTAssertEqual(result.copiedFiles, 1)
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.journalFailure)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("SOURCE.JPG")),
            contents
        )
        XCTAssertEqual(try Data(contentsOf: disconnectedSource), contents)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testCopyRejectsSamePathReplacementCapturedAfterScan() throws {
        let root = try makeTemporaryDirectory(named: "ScanReplacement")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = try makeDirectory(named: "Source", in: root)
        let destination = try makeDirectory(named: "Destination", in: root)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        let source = sourceFolder.appendingPathComponent("SOURCE.JPG")
        try Data("original".utf8).write(to: source)
        let item = makeItem(id: "SOURCE.JPG", primaryURL: source)

        try FileManager.default.removeItem(at: source)
        let replacement = Data("same path, different physical file".utf8)
        try replacement.write(to: source, options: .withoutOverwriting)

        let result = ExportWorker.copy(
            [item],
            to: destination,
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.failedPhotos, 1)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertTrue(result.journalFailure)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("SOURCE.JPG").path
            )
        )
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testCopyRollbackPreservesRacingReplacementsAndStopsBatch() throws {
        let fixture = try makeRollbackFixture(named: "CopyRollbackRace")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let race = ExportRollbackRace(fixture: fixture)

        let result = ExportWorker.copy(
            fixture.items,
            to: fixture.destination,
            journalDirectory: fixture.journals
        ) { done, _ in
            race.injectAfterFirstFile(done: done)
        }
        if let failure = race.failureDescription { XCTFail(failure) }

        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.failedPhotos, 2, "later work must stop after ambiguity")
        XCTAssertEqual(result.inconsistentPhotos, 1)
        XCTAssertTrue(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: fixture.firstSource), fixture.firstData)
        XCTAssertEqual(
            try Data(contentsOf: fixture.firstDestination),
            fixture.destinationReplacement
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.preservedFirstDestination),
            fixture.firstData,
            "the displaced operation-owned copy must be preserved"
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.secondSource),
            fixture.sourceReplacement
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.preservedSecondSource),
            fixture.secondData
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.laterSource.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.laterDestination.path)
        )
        XCTAssertTrue(
            FileOperationJournal.hasPendingOperations(directory: fixture.journals),
            "uncertain ownership must retain recovery evidence"
        )
    }

    func testCopyRollbackRechecksSourceAfterByteComparison() throws {
        let root = try makeTemporaryDirectory(named: "CopyComparisonRace")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let artifact = root.appendingPathComponent("COPY.JPG")
        let quarantine = root.appendingPathComponent("QUARANTINE.JPG")
        let preservedSource = root.appendingPathComponent("PRESERVED.JPG")
        let original = Data("irreplaceable original".utf8)
        let replacement = Data("late source replacement".utf8)
        try original.write(to: source)
        try original.write(to: artifact)
        let sourceIdentity = try FileOperationJournal.captureIdentity(at: source)
        let artifactIdentity = try FileOperationJournal.captureIdentity(at: artifact)
        var injectionError: Error?

        let removed = ExportWorker.removeVerifiedCopyForTesting(
            source: source,
            artifact: artifact,
            quarantine: quarantine,
            sourceIdentity: sourceIdentity,
            artifactIdentity: artifactIdentity
        ) {
            do {
                try FileManager.default.moveItem(
                    at: source,
                    to: preservedSource
                )
                try replacement.write(
                    to: source,
                    options: .withoutOverwriting
                )
            } catch {
                injectionError = error
            }
        }
        if let injectionError { throw injectionError }

        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertEqual(try Data(contentsOf: preservedSource), original)
        XCTAssertEqual(
            try Data(contentsOf: artifact),
            original,
            "the duplicate must remain when the original changes during comparison"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testMoveRollbackPreservesRacingReplacementsStopsAndRecovers() throws {
        let fixture = try makeRollbackFixture(named: "MoveRollbackRace")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let race = ExportRollbackRace(fixture: fixture)

        let result = ExportWorker.move(
            fixture.items,
            to: fixture.destination,
            journalDirectory: fixture.journals
        ) { done, _ in
            race.injectAfterFirstFile(done: done)
        }
        if let failure = race.failureDescription { XCTFail(failure) }

        XCTAssertTrue(result.movedItemIDs.isEmpty)
        XCTAssertEqual(result.movedFiles, 0)
        XCTAssertEqual(result.failedPhotos, 2, "later work must stop after ambiguity")
        XCTAssertEqual(result.inconsistentPhotos, 1)
        XCTAssertTrue(result.requiresRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.firstSource.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.firstDestination),
            fixture.destinationReplacement
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.preservedFirstDestination),
            fixture.firstData
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.secondSource),
            fixture.sourceReplacement
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.preservedSecondSource),
            fixture.secondData
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.laterSource.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.laterDestination.path)
        )
        XCTAssertTrue(FileOperationJournal.hasPendingOperations(directory: fixture.journals))

        // Remove only the two injected blockers, then put the exact planned
        // inodes back where recovery can verify them.
        try FileManager.default.removeItem(at: fixture.firstDestination)
        try FileManager.default.moveItem(
            at: fixture.preservedFirstDestination,
            to: fixture.firstDestination
        )
        try FileManager.default.removeItem(at: fixture.secondSource)
        try FileManager.default.moveItem(
            at: fixture.preservedSecondSource,
            to: fixture.secondSource
        )
        let recovery = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )

        XCTAssertEqual(recovery.unresolvedOperations, 0)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: fixture.journals))
        XCTAssertEqual(try Data(contentsOf: fixture.firstSource), fixture.firstData)
        XCTAssertEqual(try Data(contentsOf: fixture.secondSource), fixture.secondData)
        XCTAssertEqual(try Data(contentsOf: fixture.laterSource), fixture.laterData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.firstDestination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.laterDestination.path))
    }

    func testSuccessfulMoveRollbackRefreshesLiveScanIdentity() throws {
        let root = try makeTemporaryDirectory(named: "MoveRollbackRefresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = try makeDirectory(named: "Source", in: root)
        let destination = try makeDirectory(named: "Destination", in: root)
        let first = sourceFolder.appendingPathComponent("PAIR.NEF")
        let second = sourceFolder.appendingPathComponent("PAIR.JPG")
        let displacedSecond = root.appendingPathComponent("PAIR.external.JPG")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let item = makeItem(
            id: "PAIR.NEF",
            primaryURL: first,
            pairedURL: second
        )
        let displacer = SingleFileDisplacer(from: second, to: displacedSecond)

        let result = ExportWorker.move(
            [item],
            to: destination,
            journalDirectory: root.appendingPathComponent("Journals")
        ) { done, _ in
            displacer.injectAfterFirstFile(done: done)
        }
        if let failure = displacer.failureDescription { XCTFail(failure) }

        XCTAssertEqual(result.failedPhotos, 1)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        let refreshed = try XCTUnwrap(item.individualFiles[0].scannedIdentity)
        let current = try FileOperationJournal.captureIdentity(at: first)
        XCTAssertTrue(
            FileOperationJournal.identitiesMatch(
                expected: refreshed,
                actual: current,
                includeStatusChange: true
            ),
            "a later operation must accept the verified rolled-back original without a rescan"
        )
    }

    func testValidatedSymlinkDestinationCannotBeRetargetedAfterPreflight() throws {
        let root = try makeTemporaryDirectory(named: "DestinationSymlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = try makeDirectory(named: "Source", in: root)
        let destinationA = try makeDirectory(named: "Destination-A", in: root)
        let destinationB = try makeDirectory(named: "Destination-B", in: root)
        let alias = root.appendingPathComponent("Selected-Destination")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: destinationA
        )
        let source = sourceFolder.appendingPathComponent("PHOTO.JPG")
        let contents = Data("photo bytes".utf8)
        try contents.write(to: source)
        // Capacity APIs report zero in some XCTest sandboxes; zero keeps this
        // test focused on the canonical destination contract.
        let item = makeItem(
            id: "PHOTO.JPG",
            primaryURL: source,
            fileSize: 0
        )

        let validated = try ExportDestinationValidator.validate(
            sourceFolder: sourceFolder,
            destination: alias,
            items: [item],
            mode: .copy
        )
        let resolvedDestinationA = try FileOperationJournal
            .resolvingSymlinksExactly(destinationA)
        XCTAssertTrue(
            FileOperationJournal.exactPathsEqual(
                validated,
                resolvedDestinationA
            )
        )

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: destinationB
        )
        let result = ExportWorker.copy(
            [item],
            to: validated,
            journalDirectory: root.appendingPathComponent("Journals")
        ) { _, _ in }

        XCTAssertEqual(result.copiedFiles, 1)
        XCTAssertEqual(
            try Data(contentsOf: destinationA.appendingPathComponent("PHOTO.JPG")),
            contents
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationB.appendingPathComponent("PHOTO.JPG").path
            )
        )
    }

    func testValidatorAndCopyPreserveExactUnicodeDestinationFolder() throws {
        try assertExactUnicodeDestinations(mode: .copy)
    }

    func testValidatorAndMovePreserveExactUnicodeDestinationFolder() throws {
        try assertExactUnicodeDestinations(mode: .move)
    }

    private func assertExactUnicodeDestinations(mode: ExportMode) throws {
        let spellings: [(label: String, name: String)] = [
            ("Composed", "café destination"),
            ("Decomposed", "cafe\u{301} destination"),
        ]
        for spelling in spellings {
            let modeLabel = mode == .copy ? "Copy" : "Move"
            let root = try makeTemporaryDirectory(
                named: "Exact\(modeLabel)\(spelling.label)"
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let resolvedRoot = try FileOperationJournal
                .resolvingSymlinksExactly(root)
            let sourceFolder = try makeDirectory(
                named: "Source",
                in: resolvedRoot
            )
            let destination = try FileOperationJournal
                .appendingPathComponentExactly(spelling.name, to: resolvedRoot)
            try createExactDirectory(at: destination)
            let source = sourceFolder.appendingPathComponent("PHOTO.JPG")
            let contents = Data("exact destination bytes".utf8)
            try contents.write(to: source)
            let item = makeItem(
                id: "PHOTO.JPG",
                primaryURL: source,
                fileSize: 0
            )

            let validated = try ExportDestinationValidator.validate(
                sourceFolder: sourceFolder,
                destination: destination,
                items: [item],
                mode: mode
            )
            XCTAssertEqual(
                FileOperationJournal.exactPathBytes(for: validated),
                FileOperationJournal.exactPathBytes(for: destination),
                "validation changed the \(spelling.label.lowercased()) filesystem spelling"
            )

            let journals = resolvedRoot.appendingPathComponent("Journals")
            switch mode {
            case .copy:
                let result = ExportWorker.copy(
                    [item],
                    to: validated,
                    journalDirectory: journals
                ) { _, _ in }
                XCTAssertEqual(result.copiedFiles, 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            case .move:
                let result = ExportWorker.move(
                    [item],
                    to: validated,
                    journalDirectory: journals
                ) { _, _ in }
                XCTAssertEqual(result.movedFiles, 1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            }

            let exported = try FileOperationJournal
                .appendingPathComponentExactly("PHOTO.JPG", to: destination)
            XCTAssertEqual(try Data(contentsOf: exported), contents)
        }
    }

    private func makeRollbackFixture(named name: String) throws -> RollbackFixture {
        let root = try makeTemporaryDirectory(named: name)
        let source = try makeDirectory(named: "Source", in: root)
        let destination = try makeDirectory(named: "Destination", in: root)
        let firstSource = source.appendingPathComponent("PAIR.NEF")
        let secondSource = source.appendingPathComponent("PAIR.JPG")
        let laterSource = source.appendingPathComponent("LATER.JPG")
        let firstData = Data("first planned original".utf8)
        let secondData = Data("second planned original".utf8)
        let laterData = Data("later planned original".utf8)
        try firstData.write(to: firstSource)
        try secondData.write(to: secondSource)
        try laterData.write(to: laterSource)
        let pair = makeItem(
            id: "PAIR.NEF",
            primaryURL: firstSource,
            pairedURL: secondSource
        )
        let later = makeItem(id: "LATER.JPG", primaryURL: laterSource)
        return RollbackFixture(
            root: root,
            destination: destination,
            journals: root.appendingPathComponent("Journals", isDirectory: true),
            items: [pair, later],
            firstSource: firstSource,
            secondSource: secondSource,
            laterSource: laterSource,
            firstDestination: destination.appendingPathComponent("PAIR.NEF"),
            laterDestination: destination.appendingPathComponent("LATER.JPG"),
            preservedFirstDestination: root.appendingPathComponent("Preserved-PAIR.NEF"),
            preservedSecondSource: root.appendingPathComponent("Preserved-PAIR.JPG"),
            firstData: firstData,
            secondData: secondData,
            laterData: laterData,
            destinationReplacement: Data("racing destination replacement".utf8),
            sourceReplacement: Data("racing source replacement".utf8)
        )
    }

    private func createExactDirectory(at url: URL) throws {
        var failure: Int32 = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            let result = Darwin.mkdir(path, mode_t(0o700))
            if result != 0 { failure = errno }
            return result
        }
        guard result == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: failure) ?? .EIO
            )
        }
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LouppeExportWorkerTests-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeDirectory(named name: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeItem(
        id: String,
        primaryURL: URL,
        pairedURL: URL? = nil,
        fileSize: Int64 = 1
    ) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: primaryURL,
            pairedURL: pairedURL,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: fileSize,
            pairedFileSize: pairedURL == nil ? 0 : 1
        )
    }
}

private final class FailFirstFileCopier: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptCount = 0

    var attempts: Int {
        lock.withLock { attemptCount }
    }

    func copy(source: URL, destination: URL) throws {
        let attempt = lock.withLock { () -> Int in
            attemptCount += 1
            return attemptCount
        }
        if attempt == 1 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: "simulated removable-drive interruption"]
            )
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private final class PartialFailingFileCopier: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptCount = 0

    var attempts: Int {
        lock.withLock { attemptCount }
    }

    func copy(source _: URL, destination: URL) throws {
        lock.withLock { attemptCount += 1 }
        try Data("unverified partial bytes".utf8).write(
            to: destination,
            options: .withoutOverwriting
        )
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "simulated partial copy interruption"]
        )
    }
}

private struct RollbackFixture {
    let root: URL
    let destination: URL
    let journals: URL
    let items: [PhotoItem]
    let firstSource: URL
    let secondSource: URL
    let laterSource: URL
    let firstDestination: URL
    let laterDestination: URL
    let preservedFirstDestination: URL
    let preservedSecondSource: URL
    let firstData: Data
    let secondData: Data
    let laterData: Data
    let destinationReplacement: Data
    let sourceReplacement: Data
}

private final class ExportRollbackRace: @unchecked Sendable {
    private let lock = NSLock()
    private let fixture: RollbackFixture
    private var injected = false
    private var storedFailureDescription: String?

    init(fixture: RollbackFixture) {
        self.fixture = fixture
    }

    func injectAfterFirstFile(done: Int) {
        guard done == 1 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !injected else { return }
        injected = true
        do {
            try FileManager.default.moveItem(
                at: fixture.firstDestination,
                to: fixture.preservedFirstDestination
            )
            try fixture.destinationReplacement.write(
                to: fixture.firstDestination,
                options: .withoutOverwriting
            )
            try FileManager.default.moveItem(
                at: fixture.secondSource,
                to: fixture.preservedSecondSource
            )
            try fixture.sourceReplacement.write(
                to: fixture.secondSource,
                options: .withoutOverwriting
            )
        } catch {
            storedFailureDescription =
                "could not inject export rollback race: "
                + error.localizedDescription
        }
    }

    var failureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailureDescription
    }
}

private final class SingleFileDisplacer: @unchecked Sendable {
    private let lock = NSLock()
    private let source: URL
    private let destination: URL
    private var injected = false
    private var storedFailureDescription: String?

    init(from source: URL, to destination: URL) {
        self.source = source
        self.destination = destination
    }

    func injectAfterFirstFile(done: Int) {
        guard done == 1 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !injected else { return }
        injected = true
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            storedFailureDescription =
                "could not inject pair failure: " + error.localizedDescription
        }
    }

    var failureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailureDescription
    }
}
