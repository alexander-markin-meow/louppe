import CryptoKit
import Foundation
import XCTest
@testable import Louppe

final class XMPPhase7Tests: XCTestCase {
    func testConditionalDefaultStopsAfterManualChoiceAndResetsWithNewSheetState() {
        var choice = ExportXMPInclusionChoice()
        choice.applyRecognizedPacketCount(0)
        XCTAssertFalse(choice.isIncluded)
        choice.applyRecognizedPacketCount(2)
        XCTAssertTrue(choice.isIncluded)

        choice.setManually(false)
        choice.applyRecognizedPacketCount(4)
        XCTAssertFalse(choice.isIncluded)
        XCTAssertTrue(choice.wasManuallySet)

        var newSheet = ExportXMPInclusionChoice()
        newSheet.applyRecognizedPacketCount(1)
        XCTAssertTrue(newSheet.isIncluded)
        XCTAssertFalse(newSheet.wasManuallySet)
    }

    func testRecognizedSidecarDefaultProbeUsesResolverMatchesOnly() throws {
        let root = try temporaryDirectory("DefaultProbe")
        let media = root.appendingPathComponent("IMG_0001.NEF")
        try Data("raw".utf8).write(to: media)
        let selected = try item(media)
        try Data("unrelated".utf8).write(
            to: root.appendingPathComponent("IMG_0001-not-associated.xmp")
        )
        try Data("unrelated heavy edits".utf8).write(
            to: root.appendingPathComponent("IMG_0001-not-associated.acr")
        )

        XCTAssertEqual(
            try XMPExportPlanner.existingRecognizedPacketCount(
                selected: [selected],
                familyContextItems: [selected]
            ),
            0
        )
        XCTAssertEqual(
            try XMPExportPlanner.inspectSources(
                selected: [selected],
                familyContextItems: [selected]
            ),
            XMPExportSourceInspection(
                recognizedPacketCount: 0,
                excludedACRCompanionCount: 0
            )
        )

        try packet(decision: .yes, stars: .two, color: .green).write(
            to: root.appendingPathComponent("IMG_0001.XMP")
        )
        try Data("darktable history".utf8).write(
            to: root.appendingPathComponent("IMG_0001.NEF.xmp")
        )
        try Data("Lightroom heavy edits".utf8).write(
            to: root.appendingPathComponent("IMG_0001.ACR")
        )
        try Data("qualified Lightroom heavy edits".utf8).write(
            to: root.appendingPathComponent("IMG_0001.NEF.acr")
        )
        XCTAssertEqual(
            try XMPExportPlanner.existingRecognizedPacketCount(
                selected: [selected],
                familyContextItems: [selected]
            ),
            2
        )
        XCTAssertEqual(
            try XMPExportPlanner.inspectSources(
                selected: [selected],
                familyContextItems: [selected]
            ),
            XMPExportSourceInspection(
                recognizedPacketCount: 2,
                excludedACRCompanionCount: 2
            )
        )
    }

    func testSourceInspectionIgnoresUnselectedQualifiedSiblingPackets() throws {
        let root = try temporaryDirectory("SelectedProbe")
        let raw = root.appendingPathComponent("PAIR.NEF")
        let jpeg = root.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let selectedRAW = try item(raw)
        let unselectedJPEG = try item(jpeg)
        try Data("unselected history".utf8).write(
            to: root.appendingPathComponent("PAIR.JPG.xmp")
        )
        try Data("unselected heavy edits".utf8).write(
            to: root.appendingPathComponent("PAIR.JPG.acr")
        )

        XCTAssertEqual(
            try XMPExportPlanner.inspectSources(
                selected: [selectedRAW],
                familyContextItems: [selectedRAW, unselectedJPEG]
            ),
            XMPExportSourceInspection(
                recognizedPacketCount: 0,
                excludedACRCompanionCount: 0
            )
        )

        try packet(decision: .undecided, stars: nil, color: nil).write(
            to: root.appendingPathComponent("PAIR.xmp")
        )
        try Data("shared heavy edits".utf8).write(
            to: root.appendingPathComponent("PAIR.acr")
        )
        XCTAssertEqual(
            try XMPExportPlanner.inspectSources(
                selected: [selectedRAW],
                familyContextItems: [selectedRAW, unselectedJPEG]
            ),
            XMPExportSourceInspection(
                recognizedPacketCount: 1,
                excludedACRCompanionCount: 1
            )
        )
    }

    func testSourceInspectionCountsExistingCanonicalPacketForConflictedFamily() throws {
        let root = try temporaryDirectory("ConflictedDefaultProbe")
        let raw = root.appendingPathComponent("PAIR.NEF")
        let jpeg = root.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let selectedRAW = try item(raw, decision: .yes, stars: .five)
        let conflictingJPEG = try item(jpeg, decision: .no, stars: .one)

        XCTAssertEqual(
            try XMPExportPlanner.existingRecognizedPacketCount(
                selected: [selectedRAW],
                familyContextItems: [selectedRAW, conflictingJPEG]
            ),
            0
        )

        try packet(decision: .yes, stars: .five, color: nil).write(
            to: root.appendingPathComponent("PAIR.xmp")
        )
        XCTAssertEqual(
            try XMPExportPlanner.existingRecognizedPacketCount(
                selected: [selectedRAW],
                familyContextItems: [selectedRAW, conflictingJPEG]
            ),
            1
        )
    }

    func testCopyWithXMPMergesDestinationAndNeverChangesSourcePackets() async throws {
        let root = try temporaryDirectory("Copy")
        let source = try directory("Source", in: root)
        let destination = try directory("Destination", in: root)
        let journals = root.appendingPathComponent("Journals")
        let media = source.appendingPathComponent("COPY.NEF")
        let sidecar = source.appendingPathComponent("COPY.xmp")
        let application = source.appendingPathComponent("COPY.NEF.xmp")
        try Data("raw bytes".utf8).write(to: media)
        let sourcePacket = try fixture("universal-unknown.xmp")
        try sourcePacket.write(to: sidecar)
        let applicationPacket = Data("application-private history".utf8)
        try applicationPacket.write(to: application)
        let selected = try item(
            media,
            decision: .yes,
            stars: .five,
            color: .red
        )
        let xmp = try await XMPExportPlanner.prepare(
            selected: [selected],
            familyContextItems: [selected],
            profile: .bridge,
            visibleDecisionKeywords: true,
            allowExternalLabelReplacement: true
        )

        let result = ExportWorker.copy(
            [selected],
            to: destination,
            xmpPlan: xmp,
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertTrue(result.isSuccessful)
        XCTAssertEqual(try Data(contentsOf: sidecar), sourcePacket)
        XCTAssertEqual(try Data(contentsOf: application), applicationPacket)
        let destinationPacket = try Data(
            contentsOf: destination.appendingPathComponent("COPY.xmp")
        )
        try XMPFieldMapping.verify(
            packet: destinationPacket,
            metadata: XMPPublicationMetadata(
                decision: .yes,
                stars: .five,
                colorLabel: .red,
                profile: .bridge
            )
        )
        XCTAssertEqual(
            try XMPFieldMapping.readProperty(
                namespace: "https://example.invalid/xmp/foreign/1.0/",
                path: "Untouched",
                packet: destinationPacket
            ),
            "Unknown namespace sentinel"
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("COPY.NEF.xmp")),
            applicationPacket
        )
        XCTAssertEqual(result.xmpSummary?.mediaFiles, 1)
        XCTAssertEqual(result.xmpSummary?.updated, 1)
        XCTAssertEqual(result.xmpSummary?.copiedUnchanged, 1)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testGroupedSameStemCopyFailureReportsEverySelectedItem() async throws {
        let root = try temporaryDirectory("GroupedFailureCount")
        let source = try directory("Source", in: root)
        let destination = try directory("Destination", in: root)
        let journals = root.appendingPathComponent("Journals")
        let rawURL = source.appendingPathComponent("PAIR.NEF")
        let jpegURL = source.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: rawURL)
        try Data("jpeg".utf8).write(to: jpegURL)
        let raw = try item(rawURL, decision: .yes, stars: .three)
        let jpeg = try item(jpegURL, decision: .yes, stars: .three)
        let xmp = try await prepared([raw, jpeg], context: [raw, jpeg])

        let result = ExportWorker.copy(
            [raw, jpeg],
            to: destination,
            xmpPlan: xmp,
            journalDirectory: journals,
            fileCopier: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        ) { _, _ in }

        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.failedPhotos, 2)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testConflictedFamilyExportsMediaAndReportsSkippedXMP() async throws {
        let root = try temporaryDirectory("ConflictPreflight")
        let source = try directory("Source", in: root)
        let destination = try directory("Destination", in: root)
        let journals = root.appendingPathComponent("Journals")
        let rawURL = source.appendingPathComponent("PAIR.NEF")
        let jpegURL = source.appendingPathComponent("PAIR.JPG")
        let sidecar = source.appendingPathComponent("PAIR.xmp")
        let applicationSidecar = source.appendingPathComponent(
            "PAIR.NEF.xmp"
        )
        try Data("raw".utf8).write(to: rawURL)
        try Data("jpeg".utf8).write(to: jpegURL)
        let originalPacket = try packet(
            decision: .yes,
            stars: .five,
            color: .red
        )
        try originalPacket.write(to: sidecar)
        let applicationPacket = Data("private processing history".utf8)
        try applicationPacket.write(to: applicationSidecar)
        let raw = try item(rawURL, decision: .yes, stars: .five)
        let jpeg = try item(jpegURL, decision: .no, stars: .one)

        let xmp = try await XMPExportPlanner.prepare(
            selected: [raw],
            familyContextItems: [raw, jpeg],
            profile: .universal,
            visibleDecisionKeywords: false,
            allowExternalLabelReplacement: false
        )
        XCTAssertEqual(xmp.count(.sameStemMetadataConflict), 1)
        XCTAssertEqual(xmp.existingRecognizedPacketCount, 2)
        XCTAssertEqual(xmp.applicationPacketCount, 1)

        let result = ExportWorker.copy(
            [raw],
            to: destination,
            xmpPlan: xmp,
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertEqual(result.xmpSummary?.mediaFiles, 1)
        XCTAssertEqual(result.xmpSummary?.conflicts, 1)
        XCTAssertEqual(result.xmpSummary?.copiedUnchanged, 1)
        XCTAssertEqual(try Data(contentsOf: sidecar), originalPacket)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("PAIR.NEF").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("PAIR.xmp").path
            )
        )
        XCTAssertEqual(
            try Data(
                contentsOf: destination.appendingPathComponent(
                    "PAIR.NEF.xmp"
                )
            ),
            applicationPacket
        )
    }

    func testVideoSidecarsDoNotEnableOrJoinFirstReleaseXMPExport() async throws {
        let root = try temporaryDirectory("VideoSidecar")
        let movieURL = root.appendingPathComponent("CLIP.MOV")
        try Data("movie".utf8).write(to: movieURL)
        try Data("video sidecar".utf8).write(
            to: root.appendingPathComponent("CLIP.xmp")
        )
        let movie = PhotoItem(primaryFile: PhotoFile(
            id: movieURL.lastPathComponent,
            url: movieURL,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: .video,
            fileSize: 5,
            scannedIdentity: try FileOperationJournal.captureIdentity(
                at: movieURL
            ),
            rating: .yes
        ))

        XCTAssertEqual(
            try XMPExportPlanner.existingRecognizedPacketCount(
                selected: [movie],
                familyContextItems: [movie]
            ),
            0
        )
        let prepared = try await XMPExportPlanner.prepare(
            selected: [movie],
            familyContextItems: [movie],
            profile: .universal,
            visibleDecisionKeywords: false,
            allowExternalLabelReplacement: false
        )
        XCTAssertEqual(prepared.count(.unsupportedMedia), 1)
        XCTAssertEqual(prepared.existingRecognizedPacketCount, 0)
        XCTAssertEqual(prepared.applicationPacketCount, 0)
    }

    func testMoveWithoutXMPLeavesSourceSidecarUntouched() throws {
        let root = try temporaryDirectory("MoveOff")
        let source = try directory("Source", in: root)
        let destination = try directory("Destination", in: root)
        let journals = root.appendingPathComponent("Journals")
        let media = source.appendingPathComponent("OFF.NEF")
        let sidecar = source.appendingPathComponent("OFF.xmp")
        try Data("raw".utf8).write(to: media)
        let originalPacket = try packet(
            decision: .no,
            stars: .one,
            color: .purple
        )
        try originalPacket.write(to: sidecar)
        let selected = try item(media)

        let result = ExportWorker.move(
            [selected],
            to: destination,
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertEqual(result.movedItemIDs, [selected.id])
        XCTAssertEqual(try Data(contentsOf: sidecar), originalPacket)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("OFF.NEF").path
            )
        )
    }

    func testMoveWithXMPTransfersFullySelectedCanonicalPacket() async throws {
        let root = try temporaryDirectory("MoveOn")
        let source = try directory("Source", in: root)
        let destination = try directory("Destination", in: root)
        let journals = root.appendingPathComponent("Journals")
        let media = source.appendingPathComponent("MOVE.NEF")
        let sidecar = source.appendingPathComponent("MOVE.xmp")
        try Data("raw".utf8).write(to: media)
        try packet(decision: .no, stars: .one, color: .yellow).write(to: sidecar)
        let selected = try item(
            media,
            decision: .yes,
            stars: .four,
            color: .blue
        )
        let xmp = try await prepared([selected], context: [selected])

        let result = ExportWorker.move(
            [selected],
            to: destination,
            xmpPlan: xmp,
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertEqual(result.movedItemIDs, [selected.id])
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        try XMPFieldMapping.verify(
            packet: Data(contentsOf: destination.appendingPathComponent("MOVE.xmp")),
            metadata: XMPPublicationMetadata(
                decision: .yes,
                stars: .four,
                colorLabel: .blue,
                profile: .universal
            )
        )
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testMovingOneSameStemMemberCopiesSharedPacketAndKeepsSource() async throws {
        let root = try temporaryDirectory("SharedMove")
        let source = try directory("Source", in: root)
        let destination = try directory("Destination", in: root)
        let journals = root.appendingPathComponent("Journals")
        let raw = source.appendingPathComponent("PAIR.NEF")
        let jpeg = source.appendingPathComponent("PAIR.JPG")
        let sidecar = source.appendingPathComponent("PAIR.xmp")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let originalPacket = try packet(
            decision: .yes,
            stars: .three,
            color: .green
        )
        try originalPacket.write(to: sidecar)
        let selectedRAW = try item(
            raw,
            decision: .yes,
            stars: .five,
            color: .red
        )
        let remainingJPEG = try item(
            jpeg,
            decision: .yes,
            stars: .five,
            color: .red
        )
        let xmp = try await prepared(
            [selectedRAW],
            context: [selectedRAW, remainingJPEG]
        )

        let result = ExportWorker.move(
            [selectedRAW],
            to: destination,
            xmpPlan: xmp,
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertEqual(result.movedItemIDs, [selectedRAW.id])
        XCTAssertEqual(try Data(contentsOf: sidecar), originalPacket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("PAIR.xmp").path
            )
        )
    }

    func testXMPDestinationCollisionSuffixesWholeFamilyWithoutOverwrite() async throws {
        let root = try temporaryDirectory("Collision")
        let source = try directory("Source", in: root)
        let destination = try directory("Destination", in: root)
        let journals = root.appendingPathComponent("Journals")
        let media = source.appendingPathComponent("COLLIDE.NEF")
        try Data("raw".utf8).write(to: media)
        let existingDestination = Data("foreign destination".utf8)
        try existingDestination.write(
            to: destination.appendingPathComponent("COLLIDE.xmp")
        )
        let selected = try item(media, stars: .two, color: .yellow)
        let xmp = try await prepared([selected], context: [selected])

        let result = ExportWorker.copy(
            [selected],
            to: destination,
            xmpPlan: xmp,
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertTrue(result.isSuccessful)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("COLLIDE.xmp")),
            existingDestination
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("COLLIDE (1).NEF").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("COLLIDE (1).xmp").path
            )
        )
    }

    func testPreparedPacketRecoveryAtStartedStagedAndCompletedCheckpoints() throws {
        for checkpoint in ["started", "staged", "completed"] {
            let root = try temporaryDirectory("Recovery-\(checkpoint)")
            let source = root.appendingPathComponent("ANCHOR.NEF")
            let destination = root.appendingPathComponent("ANCHOR.xmp")
            let journals = root.appendingPathComponent("Journals")
            try Data("anchor".utf8).write(to: source)
            let packet = Data("final prepared packet".utf8)
            let writer = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: [.init(
                    itemID: "family",
                    source: source,
                    destination: destination,
                    expectedIdentity: try FileOperationJournal.captureIdentity(at: source),
                    role: .preparedXMP,
                    preparedContentDigest: Data(SHA256.hash(data: packet))
                )],
                directory: journals
            )
            XCTAssertEqual(writer.plan.version, 4)
            let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
            try writer.mark(.started, fileAt: 0)
            try DurableFileIO.writeNewFile(packet, to: temporary, fullSync: true)
            let stagedIdentity = try FileOperationJournal.captureIdentity(at: temporary)
            if checkpoint != "started" {
                try writer.mark(
                    .staged,
                    fileAt: 0,
                    identityAt: temporary,
                    expectedIdentity: stagedIdentity,
                    includeStatusChange: false
                )
            }
            if checkpoint == "completed" {
                try DurableFileIO.atomicExclusiveRename(
                    from: temporary,
                    to: destination
                )
                let completedIdentity = try FileOperationJournal.captureIdentity(
                    at: destination
                )
                try writer.mark(
                    .completed,
                    fileAt: 0,
                    identityAt: destination,
                    expectedIdentity: completedIdentity,
                    includeStatusChange: false
                )
            }
            XCTAssertTrue(FileOperationJournal.finalize(
                writer,
                operationIsConsistent: false
            ))

            let report = FileOperationJournal.recoverPendingOperations(
                directory: journals
            )
            XCTAssertEqual(report.unresolvedOperations, 0, checkpoint)
            XCTAssertEqual(try Data(contentsOf: destination), packet, checkpoint)
            XCTAssertFalse(
                FileOperationJournal.hasPendingOperations(directory: journals),
                checkpoint
            )
        }
    }

    func testRetiredPacketRecoveryRollsBackIncompleteFamilyAndCommitsCompleteFamily() throws {
        for retirementCompleted in [false, true] {
            let label = retirementCompleted ? "complete" : "staged"
            let root = try temporaryDirectory("Retirement-\(label)")
            let sourceMedia = root.appendingPathComponent("MOVE.NEF")
            let sourceXMP = root.appendingPathComponent("MOVE.xmp")
            let destinationMedia = root.appendingPathComponent("DONE.NEF")
            let holdingXMP = root.appendingPathComponent(".retired-xmp")
            let journals = root.appendingPathComponent("Journals")
            try Data("media".utf8).write(to: sourceMedia)
            let xmpBytes = Data("source packet preserved at destination".utf8)
            try xmpBytes.write(to: sourceXMP)
            let writer = try FileOperationJournal.start(
                kind: .exportMove,
                seeds: [
                    .init(
                        itemID: "family",
                        source: sourceMedia,
                        destination: destinationMedia,
                        expectedIdentity: try FileOperationJournal.captureIdentity(
                            at: sourceMedia
                        )
                    ),
                    .init(
                        itemID: "family",
                        source: sourceXMP,
                        destination: holdingXMP,
                        expectedIdentity: try FileOperationJournal.captureIdentity(
                            at: sourceXMP
                        ),
                        role: .retiredXMPSource,
                        expectedSourceDigest: Data(SHA256.hash(data: xmpBytes))
                    ),
                ],
                directory: journals
            )

            try moveThroughCompletedCheckpoint(
                writer: writer,
                index: 0,
                source: sourceMedia,
                destination: destinationMedia
            )

            try writer.mark(.started, fileAt: 1)
            let xmpTemporary = try XCTUnwrap(writer.temporaryURL(at: 1))
            try DurableFileIO.atomicExclusiveRename(
                from: sourceXMP,
                to: xmpTemporary
            )
            let stagedIdentity = try FileOperationJournal.captureIdentity(
                at: xmpTemporary
            )
            try writer.mark(
                .staged,
                fileAt: 1,
                identityAt: xmpTemporary,
                expectedIdentity: stagedIdentity
            )
            if retirementCompleted {
                try DurableFileIO.atomicExclusiveRename(
                    from: xmpTemporary,
                    to: holdingXMP
                )
                let completedIdentity = try FileOperationJournal.captureIdentity(
                    at: holdingXMP
                )
                try writer.mark(
                    .completed,
                    fileAt: 1,
                    identityAt: holdingXMP,
                    expectedIdentity: completedIdentity
                )
            }
            XCTAssertTrue(FileOperationJournal.finalize(
                writer,
                operationIsConsistent: false
            ))

            let report = FileOperationJournal.recoverPendingOperations(
                directory: journals
            )
            XCTAssertEqual(report.unresolvedOperations, 0, label)
            if retirementCompleted {
                XCTAssertTrue(FileManager.default.fileExists(atPath: destinationMedia.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceMedia.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceXMP.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: holdingXMP.path))
            } else {
                XCTAssertTrue(FileManager.default.fileExists(atPath: sourceMedia.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: destinationMedia.path))
                XCTAssertEqual(try Data(contentsOf: sourceXMP), xmpBytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: xmpTemporary.path))
            }
        }
    }

    func testIncompleteMoveRollsBackCompletedPreparedPacketBeforeRetirement() throws {
        let root = try temporaryDirectory("PreparedMoveRollback")
        let sourceMedia = root.appendingPathComponent("SOURCE.NEF")
        let sourceXMP = root.appendingPathComponent("SOURCE.xmp")
        let destinationMedia = root.appendingPathComponent("DEST.NEF")
        let destinationXMP = root.appendingPathComponent("DEST.xmp")
        let holdingXMP = root.appendingPathComponent(".retired-xmp")
        let journals = root.appendingPathComponent("Journals")
        try Data("media".utf8).write(to: sourceMedia)
        let originalPacket = Data("original packet".utf8)
        let finalPacket = Data("merged destination packet".utf8)
        try originalPacket.write(to: sourceXMP)
        let writer = try FileOperationJournal.start(
            kind: .exportMove,
            seeds: [
                .init(
                    itemID: "family",
                    source: sourceMedia,
                    destination: destinationMedia,
                    expectedIdentity: try FileOperationJournal.captureIdentity(
                        at: sourceMedia
                    )
                ),
                .init(
                    itemID: "family",
                    source: sourceXMP,
                    destination: destinationXMP,
                    expectedIdentity: try FileOperationJournal.captureIdentity(
                        at: sourceXMP
                    ),
                    role: .preparedXMP,
                    expectedSourceDigest: Data(SHA256.hash(data: originalPacket)),
                    preparedContentDigest: Data(SHA256.hash(data: finalPacket))
                ),
                .init(
                    itemID: "family",
                    source: sourceXMP,
                    destination: holdingXMP,
                    expectedIdentity: try FileOperationJournal.captureIdentity(
                        at: sourceXMP
                    ),
                    role: .retiredXMPSource,
                    expectedSourceDigest: Data(SHA256.hash(data: originalPacket))
                ),
            ],
            directory: journals
        )
        try moveThroughCompletedCheckpoint(
            writer: writer,
            index: 0,
            source: sourceMedia,
            destination: destinationMedia
        )
        let preparedTemporary = try XCTUnwrap(writer.temporaryURL(at: 1))
        try writer.mark(.started, fileAt: 1)
        try DurableFileIO.writeNewFile(
            finalPacket,
            to: preparedTemporary,
            fullSync: true
        )
        let stagedIdentity = try FileOperationJournal.captureIdentity(
            at: preparedTemporary
        )
        try writer.mark(
            .staged,
            fileAt: 1,
            identityAt: preparedTemporary,
            expectedIdentity: stagedIdentity,
            includeStatusChange: false
        )
        try DurableFileIO.atomicExclusiveRename(
            from: preparedTemporary,
            to: destinationXMP
        )
        let completedIdentity = try FileOperationJournal.captureIdentity(
            at: destinationXMP
        )
        try writer.mark(
            .completed,
            fileAt: 1,
            identityAt: destinationXMP,
            expectedIdentity: completedIdentity,
            includeStatusChange: false
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceMedia.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationMedia.path))
        XCTAssertEqual(try Data(contentsOf: sourceXMP), originalPacket)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationXMP.path))
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    private func prepared(
        _ selected: [PhotoItem],
        context: [PhotoItem]
    ) async throws -> XMPExportPreparedPlan {
        try await XMPExportPlanner.prepare(
            selected: selected,
            familyContextItems: context,
            profile: .universal,
            visibleDecisionKeywords: false,
            allowExternalLabelReplacement: false
        )
    }

    private func moveThroughCompletedCheckpoint(
        writer: FileOperationJournal.Writer,
        index: Int,
        source: URL,
        destination: URL
    ) throws {
        try writer.mark(.started, fileAt: index)
        let temporary = try XCTUnwrap(writer.temporaryURL(at: index))
        try DurableFileIO.atomicExclusiveRename(from: source, to: temporary)
        let stagedIdentity = try FileOperationJournal.captureIdentity(at: temporary)
        try writer.mark(
            .staged,
            fileAt: index,
            identityAt: temporary,
            expectedIdentity: stagedIdentity
        )
        try DurableFileIO.atomicExclusiveRename(
            from: temporary,
            to: destination
        )
        let completedIdentity = try FileOperationJournal.captureIdentity(
            at: destination
        )
        try writer.mark(
            .completed,
            fileAt: index,
            identityAt: destination,
            expectedIdentity: completedIdentity
        )
    }

    private func item(
        _ url: URL,
        decision: Rating = .yes,
        stars: StarRating? = nil,
        color: PhotoColorLabel? = nil
    ) throws -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(
            id: url.lastPathComponent,
            url: url,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: Int64((try? Data(contentsOf: url).count) ?? 0),
            scannedIdentity: try FileOperationJournal.captureIdentity(at: url),
            rating: decision,
            starRating: stars,
            colorLabel: color
        ))
    }

    private func packet(
        decision: Rating,
        stars: StarRating?,
        color: PhotoColorLabel?
    ) throws -> Data {
        try XMPFieldMapping.merge(
            packet: nil,
            metadata: XMPPublicationMetadata(
                decision: decision,
                stars: stars,
                colorLabel: color,
                profile: .universal
            )
        )
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "louppe-xmp-phase7-\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func directory(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func fixture(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = tests.deletingLastPathComponent().deletingLastPathComponent()
        return try Data(
            contentsOf: repository
                .appendingPathComponent("Prototypes/XMPBridgeProof/Fixtures")
                .appendingPathComponent(name)
        )
    }
}

private extension ExportWorker.CopyResult {
    var isSuccessful: Bool {
        copiedFiles > 0
            && failedPhotos == 0
            && inconsistentPhotos == 0
            && !journalFailure
            && !requiresRecovery
    }
}
