import Darwin
import Foundation
import XCTest
@testable import Louppe

final class FileOperationJournalTests: XCTestCase {
    @MainActor
    func testSessionStoreDoesNotInspectInjectedJournalUnlessExplicitlyEnabled() throws {
        let fixture = try makeFixture(named: "SessionStoreRecoveryIsolation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let store = SessionStore(
            operationJournalDirectory: fixture.journals
        )

        XCTAssertFalse(store.isRecoveringInterruptedOperations)
        XCTAssertNil(store.operationRecoveryReport)
        XCTAssertTrue(
            FileOperationJournal.hasPendingOperations(directory: fixture.journals),
            "constructing a test store must not reconcile user-like journal state"
        )
    }

    func testRecoveryKeepsCompletedCopyWhenSourceDriveIsUnavailable() throws {
        let fixture = try makeFixture(named: "CompletedCopyOfflineSource")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(at: fixture.source, to: temporary)
        try writer.mark(.staged, fileAt: 0, identityAt: temporary)
        try FileManager.default.moveItem(at: temporary, to: fixture.destination)
        try writer.mark(.completed, fileAt: 0, identityAt: fixture.destination)
        try FileManager.default.removeItem(at: fixture.source)
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )

        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.preservedCopies, 1)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination),
            Data("source".utf8)
        )
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(directory: fixture.journals)
        )
    }

    func testRecoveryPublishesStagedCopyWhenSourceDriveIsUnavailable() throws {
        let fixture = try makeFixture(named: "StagedCopyOfflineSource")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(at: fixture.source, to: temporary)
        try writer.mark(.staged, fileAt: 0, identityAt: temporary)
        try FileManager.default.removeItem(at: fixture.source)
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )

        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.preservedCopies, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination),
            Data("source".utf8)
        )
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(directory: fixture.journals)
        )
    }

    func testRecoveryPublishesCompleteCopyWhoseStagedCheckpointWasMissed() throws {
        let fixture = try makeFixture(named: "CompleteStartedCopy")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(at: fixture.source, to: temporary)
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )

        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.preservedCopies, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination),
            Data("source".utf8)
        )
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
    }

    func testRecoveryRemovesIdentityRecordedPartialCopy() throws {
        let fixture = try makeFixture(named: "RecordedPartialCopy")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
        try writer.mark(.started, fileAt: 0)
        try Data("partial".utf8).write(
            to: temporary,
            options: .withoutOverwriting
        )
        let partialIdentity = try FileOperationJournal.captureIdentity(
            at: temporary
        )
        try writer.mark(
            .started,
            fileAt: 0,
            identityAt: temporary,
            expectedIdentity: partialIdentity,
            includeStatusChange: false
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )

        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.removedPartialCopies, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("source".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testCopyCheckpointAcceptsMetadataOnlyStatusChange() throws {
        let fixture = try makeFixture(named: "CopyMetadataChange")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
        try writer.mark(.started, fileAt: 0)
        try FileManager.default.copyItem(at: fixture.source, to: temporary)
        let beforeMetadata = try FileOperationJournal.captureIdentity(
            at: temporary
        )
        usleep(2_000)
        XCTAssertEqual(chmod(temporary.path, mode_t(0o600)), 0)
        let afterMetadata = try FileOperationJournal.captureIdentity(
            at: temporary
        )
        XCTAssertNotEqual(
            beforeMetadata.statusChangeTime,
            afterMetadata.statusChangeTime
        )
        XCTAssertTrue(FileOperationJournal.identitiesMatch(
            expected: beforeMetadata,
            actual: afterMetadata,
            includeStatusChange: false
        ))
        XCTAssertFalse(FileOperationJournal.identitiesMatch(
            expected: beforeMetadata,
            actual: afterMetadata,
            includeStatusChange: true
        ))

        try writer.mark(
            .staged,
            fileAt: 0,
            identityAt: temporary,
            expectedIdentity: beforeMetadata,
            includeStatusChange: false
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))
        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.preservedCopies, 1)
    }

    func testSuccessfulFinalizeRetiresActiveJournalBeforeCleanup() throws {
        let fixture = try makeFixture(named: "SuccessfulRetirement")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )

        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: true
        ))
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: fixture.journals,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(contents.contains {
            $0.pathExtension == "operation" || $0.pathExtension == "retired"
        })
    }

    func testRecoveryCleansStaleRetiredDirectoriesWithoutActivatingThem() throws {
        let fixture = try makeFixture(named: "StaleRetirement")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stale = fixture.journals.appendingPathComponent(
            "00000000-0000-0000-0000-000000000001-00000000-0000-0000-0000-000000000002.retired",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stale,
            withIntermediateDirectories: true
        )
        try Data("incomplete cleanup".utf8).write(
            to: stale.appendingPathComponent("fragment")
        )

        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.discoveredOperations, 0)
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testRecoveryRefusesSymlinkedPlanFile() throws {
        let fixture = try makeFixture(named: "SymlinkedPlan")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let plan = writer.token.directory.appendingPathComponent("plan.json")
        let externalPlan = fixture.root.appendingPathComponent("external-plan.json")
        try FileManager.default.moveItem(at: plan, to: externalPlan)
        try FileManager.default.createSymbolicLink(
            at: plan,
            withDestinationURL: externalPlan
        )

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.unresolvedOperations, 1)
        XCTAssertEqual(report.unresolvedFiles, 1)
        XCTAssertTrue(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalPlan.path))
    }

    func testOperationLockRefusesLeafSymlink() throws {
        let fixture = try makeFixture(named: "SymlinkedLock")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.journals,
            withIntermediateDirectories: true
        )
        let lockTarget = fixture.root.appendingPathComponent("lock-target")
        let targetContents = Data("must not become a lock".utf8)
        try targetContents.write(to: lockTarget)
        try FileManager.default.createSymbolicLink(
            at: fixture.journals.appendingPathComponent(".operation.lock"),
            withDestinationURL: lockTarget
        )

        XCTAssertThrowsError(
            try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: fixture.source,
                        destination: fixture.destination
                    ),
                ],
                directory: fixture.journals
            )
        )
        XCTAssertEqual(try Data(contentsOf: lockTarget), targetContents)
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
    }

    func testFinalizeRetainsActiveJournalWhenCommitMarkerCannotBeWritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LouppeJournalFinalizeTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("COPY.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("source".utf8).write(to: source)

        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: source,
                    destination: destination
                ),
            ],
            directory: journals
        )

        // A directory at the marker path deterministically makes the atomic
        // marker write fail without altering any photographed file.
        let commitMarker = writer.token.directory.appendingPathComponent(
            "committed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: commitMarker,
            withIntermediateDirectories: false
        )

        XCTAssertFalse(
            FileOperationJournal.finalize(
                writer,
                operationIsConsistent: true
            ),
            "finalization must report that durable commit did not complete"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: writer.token.directory.path),
            "a failed commit marker must not erase the active journal"
        )
        XCTAssertTrue(
            FileOperationJournal.hasPendingOperations(directory: journals),
            "the retained operation must remain visible to recovery"
        )

        // Once the injected obstruction is gone, normal recovery can safely
        // reconcile this no-mutation operation and retire its journal.
        try FileManager.default.removeItem(at: commitMarker)
        let report = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.restoredOperations, 1)
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(directory: journals)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCheckpointRefusesReplacementThatRacesAfterWorkerValidation() throws {
        let fixture = try makeFixture(named: "CheckpointReplacement")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        try writer.mark(.started, fileAt: 0)
        let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
        try Data("owned copy".utf8).write(to: temporary)
        let ownedIdentity = try FileOperationJournal.captureIdentity(
            at: temporary
        )

        try FileManager.default.removeItem(at: temporary)
        let replacement = Data("unrelated replacement".utf8)
        try replacement.write(to: temporary)

        XCTAssertThrowsError(
            try writer.mark(
                .staged,
                fileAt: 0,
                identityAt: temporary,
                expectedIdentity: ownedIdentity
            )
        )
        XCTAssertTrue(
            FileOperationJournal.finalize(
                writer,
                operationIsConsistent: false
            )
        )

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.unresolvedOperations, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: temporary), replacement)
        XCTAssertTrue(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
    }

    func testMutatingJournalRejectsSingleSourceWithAnotherHardLink() throws {
        let fixture = try makeFixture(named: "ExternalHardLink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.root.appendingPathComponent("ALIAS.JPG")
        try FileManager.default.linkItem(at: fixture.source, to: alias)

        XCTAssertThrowsError(
            try FileOperationJournal.start(
                kind: .moveToTrash,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: fixture.source,
                        destination: nil,
                        expectedIdentity:
                            FileOperationJournal.captureIdentity(
                                at: fixture.source
                            )
                    ),
                ],
                directory: fixture.journals
            )
        )
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: alias), Data("source".utf8))
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
    }

    func testVersionThreePlanRoundTripsExactComposedAndDecomposedPathsAndRecoversMoves() throws {
        let fixture = try makeFixture(named: "ExactUnicodeMove")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.source)
        let firstFolder = fixture.root.appendingPathComponent(
            "First",
            isDirectory: true
        )
        let secondFolder = fixture.root.appendingPathComponent(
            "Second",
            isDirectory: true
        )
        let destinationFolder = fixture.root.appendingPathComponent(
            "Destination",
            isDirectory: true
        )
        for folder in [firstFolder, secondFolder, destinationFolder] {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }

        let composedName = Array("café.jpg".utf8)
        let decomposedName = Array("cafe\u{301}.jpg".utf8)
        let firstSource = try rawChildURL(
            in: firstFolder,
            nameBytes: composedName
        )
        let secondSource = try rawChildURL(
            in: secondFolder,
            nameBytes: decomposedName
        )
        let firstDestination = try rawChildURL(
            in: destinationFolder,
            nameBytes: composedName
        )
        let secondDestination = try rawChildURL(
            in: destinationFolder,
            nameBytes: decomposedName
        )
        try Data("composed".utf8).write(to: firstSource)
        try Data("decomposed".utf8).write(to: secondSource)

        let writer = try FileOperationJournal.start(
            kind: .exportMove,
            seeds: [
                .init(
                    itemID: "composed",
                    source: firstSource,
                    destination: firstDestination
                ),
                .init(
                    itemID: "decomposed",
                    source: secondSource,
                    destination: secondDestination
                ),
            ],
            directory: fixture.journals
        )
        XCTAssertEqual(writer.plan.version, 3)
        let decoded = try decodePlan(
            at: writer.token.directory.appendingPathComponent("plan.json")
        )
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(
            decoded.files[0].sourcePathBytes,
            FileOperationJournal.exactPathBytes(for: firstSource)
        )
        XCTAssertEqual(
            decoded.files[1].sourcePathBytes,
            FileOperationJournal.exactPathBytes(for: secondSource)
        )
        XCTAssertNotEqual(
            decoded.files[0].sourcePathBytes,
            decoded.files[1].sourcePathBytes
        )
        XCTAssertEqual(
            decoded.files[0].destinationPathBytes,
            FileOperationJournal.exactPathBytes(for: firstDestination)
        )
        XCTAssertEqual(
            decoded.files[1].destinationPathBytes,
            FileOperationJournal.exactPathBytes(for: secondDestination)
        )

        for (index, source) in [firstSource, secondSource].enumerated() {
            try writer.mark(.started, fileAt: index)
            let temporary = try XCTUnwrap(writer.temporaryURL(at: index))
            try DurableFileIO.atomicExclusiveRename(
                from: source,
                to: temporary
            )
            let temporaryIdentity = try FileOperationJournal.captureIdentity(
                at: temporary
            )
            try writer.mark(
                .staged,
                fileAt: index,
                identityAt: temporary,
                expectedIdentity: temporaryIdentity
            )
        }
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.restoredFiles, 2)
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(try Data(contentsOf: firstSource), Data("composed".utf8))
        XCTAssertEqual(
            try Data(contentsOf: secondSource),
            Data("decomposed".utf8)
        )
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
    }

    func testResolvedTrashDestinationRoundTripsExactBytesAndRecoveryUsesThem() throws {
        let fixture = try makeFixture(named: "ExactTrashDestination")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.source)
        let sourceFolder = fixture.root.appendingPathComponent(
            "Source",
            isDirectory: true
        )
        let trashFolder = fixture.root.appendingPathComponent(
            "Trash",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceFolder,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trashFolder,
            withIntermediateDirectories: true
        )
        let source = try rawChildURL(
            in: sourceFolder,
            nameBytes: Array("café.jpg".utf8)
        )
        let trash = try rawChildURL(
            in: trashFolder,
            nameBytes: Array("cafe\u{301}.jpg".utf8)
        )
        try Data("irreplaceable".utf8).write(to: source)
        let writer = try FileOperationJournal.start(
            kind: .moveToTrash,
            seeds: [
                .init(
                    itemID: "photo",
                    source: source,
                    destination: nil
                ),
            ],
            directory: fixture.journals
        )
        try writer.mark(.started, fileAt: 0)
        try DurableFileIO.atomicExclusiveRename(from: source, to: trash)
        let trashIdentity = try FileOperationJournal.captureIdentity(at: trash)
        try writer.mark(
            .completed,
            fileAt: 0,
            resolvedDestination: trash,
            identityAt: trash,
            expectedIdentity: trashIdentity
        )

        let state = try decodeState(
            at: writer.token.directory
                .appendingPathComponent("steps", isDirectory: true)
                .appendingPathComponent("00000000.json")
        )
        XCTAssertEqual(
            state.resolvedDestinationPathBytes,
            FileOperationJournal.exactPathBytes(for: trash)
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.restoredFiles, 1)
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(
            try Data(contentsOf: source),
            Data("irreplaceable".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
    }

    func testVersionTwoPlanWithoutRawPathFieldsRemainsReadable() throws {
        let fixture = try makeFixture(named: "LegacyVersionTwo")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = try FileOperationJournal.start(
            kind: .exportCopy,
            seeds: [
                .init(
                    itemID: "SOURCE.JPG",
                    source: fixture.source,
                    destination: fixture.destination
                ),
            ],
            directory: fixture.journals
        )
        let legacyFiles = writer.plan.files.map {
            FileOperationJournal.PlannedFile(
                itemID: $0.itemID,
                sourcePath: $0.sourcePath,
                destinationPath: $0.destinationPath,
                temporaryPath: $0.temporaryPath,
                identity: $0.identity
            )
        }
        let legacyPlan = FileOperationJournal.Plan(
            version: 2,
            operationID: writer.plan.operationID,
            kind: writer.plan.kind,
            createdAt: writer.plan.createdAt,
            files: legacyFiles
        )
        try encodePlan(legacyPlan).write(
            to: writer.token.directory.appendingPathComponent("plan.json"),
            options: .atomic
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.restoredOperations, 1)
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testVersionThreeInvalidUTF8AndRelativeRawPathsFailClosed() throws {
        for (name, invalidBytes) in [
            ("InvalidUTF8", Data([0x2f, 0x74, 0x6d, 0x70, 0x2f, 0xff])),
            ("Relative", Data("relative/source.jpg".utf8)),
        ] {
            let fixture = try makeFixture(named: name)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let writer = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [
                    .init(
                        itemID: "SOURCE.JPG",
                        source: fixture.source,
                        destination: fixture.destination
                    ),
                ],
                directory: fixture.journals
            )
            let original = writer.plan.files[0]
            let invalid = FileOperationJournal.PlannedFile(
                itemID: original.itemID,
                sourcePath: original.sourcePath,
                destinationPath: original.destinationPath,
                temporaryPath: original.temporaryPath,
                identity: original.identity,
                sourcePathBytes: invalidBytes,
                destinationPathBytes: original.destinationPathBytes,
                temporaryPathBytes: original.temporaryPathBytes
            )
            let invalidPlan = FileOperationJournal.Plan(
                version: 3,
                operationID: writer.plan.operationID,
                kind: writer.plan.kind,
                createdAt: writer.plan.createdAt,
                files: [invalid]
            )
            try encodePlan(invalidPlan).write(
                to: writer.token.directory.appendingPathComponent("plan.json"),
                options: .atomic
            )
            XCTAssertTrue(FileOperationJournal.finalize(
                writer,
                operationIsConsistent: false
            ))

            let report = FileOperationJournal.recoverPendingOperations(
                directory: fixture.journals
            )
            XCTAssertEqual(report.unresolvedOperations, 1)
            XCTAssertTrue(report.hasUnresolvedFiles)
            XCTAssertEqual(
                try Data(contentsOf: fixture.source),
                Data("source".utf8)
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.destination.path
                )
            )
            XCTAssertTrue(
                FileOperationJournal.hasPendingOperations(
                    directory: fixture.journals
                )
            )
        }
    }

    private func rawChildURL(
        in directory: URL,
        nameBytes: [UInt8]
    ) throws -> URL {
        var bytes = try XCTUnwrap(
            FileOperationJournal.exactPathBytes(for: directory)
        )
        bytes.append(UInt8(ascii: "/"))
        bytes.append(contentsOf: nameBytes)
        var terminated = bytes
        terminated.append(0)
        return terminated.withUnsafeBytes { rawBuffer in
            URL(
                fileURLWithFileSystemRepresentation: rawBuffer.baseAddress!
                    .assumingMemoryBound(to: CChar.self),
                isDirectory: false,
                relativeTo: nil
            )
        }
    }

    private func decodePlan(
        at url: URL
    ) throws -> FileOperationJournal.Plan {
        try journalDecoder.decode(
            FileOperationJournal.Plan.self,
            from: Data(contentsOf: url)
        )
    }

    private func decodeState(
        at url: URL
    ) throws -> FileOperationJournal.StateRecord {
        try journalDecoder.decode(
            FileOperationJournal.StateRecord.self,
            from: Data(contentsOf: url)
        )
    }

    private func encodePlan(
        _ plan: FileOperationJournal.Plan
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(plan)
    }

    private var journalDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeFixture(
        named name: String
    ) throws -> (root: URL, source: URL, destination: URL, journals: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LouppeJournalTests-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("SOURCE.JPG")
        let destination = root.appendingPathComponent("COPY.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("source".utf8).write(to: source)
        return (root, source, destination, journals)
    }
}
