import Foundation
import XCTest
@testable import Louppe

@MainActor
final class RAWJPEGXMPResolutionTests: XCTestCase {
    func testFreshStoreAndDefaultScanKeepRAWAndJPEGSeparate() throws {
        let store = SessionStore()
        XCTAssertEqual(store.rawJPEGPairingMode, .separate)

        let folder = try temporaryDirectory(named: "DefaultSeparate")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("raw".utf8).write(
            to: folder.appendingPathComponent("IMG_0001.NEF")
        )
        try Data("jpeg".utf8).write(
            to: folder.appendingPathComponent("IMG_0001.JPG")
        )

        let separated = try FolderScanner.scan(folder) { _ in }
        XCTAssertEqual(separated.count, 2)
        XCTAssertTrue(separated.allSatisfy { $0.pairedFile == nil })

        let grouped = try FolderScanner.scan(
            folder,
            pairingMode: .together
        ) { _ in }
        XCTAssertEqual(grouped.count, 1)
        XCTAssertNotNil(grouped[0].pairedFile)
    }

    func testConflictDescriptorIncludesExcludedSiblingAndTypedEligibility() async throws {
        let fixture = try makePair(
            named: "Descriptor",
            rawMetadata: (.yes, .five, .green),
            jpegMetadata: (.no, .two, .red)
        )
        defer { try? FileManager.default.removeItem(at: fixture.folder) }

        let input = try XMPPublicationInput(
            items: [fixture.rawItem],
            familyContextItems: [fixture.rawItem, fixture.jpegItem],
            sessionGeneration: 73,
            profile: .captureOne,
            visibleDecisionKeywords: true
        )
        let maybePlan = await XMPPublicationPlanner.preflight(
            input,
            isCancelled: { false },
            progress: { _, _ in }
        )
        let plan = try XCTUnwrap(maybePlan)
        let conflict = try XCTUnwrap(plan.resolvableSameStemConflicts.only)

        XCTAssertEqual(conflict.sessionGeneration, 73)
        XCTAssertEqual(conflict.resolutionEligibility, .eligible)
        XCTAssertEqual(
            conflict.differingDimensions,
            [.decision, .stars, .color]
        )
        XCTAssertEqual(conflict.rawMember?.wasSelectedForExport, true)
        XCTAssertEqual(conflict.jpegMember?.wasSelectedForExport, false)
        XCTAssertEqual(conflict.rawMember?.filename, "IMG_0001.NEF")
        XCTAssertEqual(conflict.jpegMember?.filename, "IMG_0001.JPG")
    }

    func testTwoRAWConflictIsTypedButNeverResolvable() async throws {
        let folder = try temporaryDirectory(named: "TwoRAWs")
        defer { try? FileManager.default.removeItem(at: folder) }
        let nef = folder.appendingPathComponent("IMG_0001.NEF")
        let cr3 = folder.appendingPathComponent("IMG_0001.CR3")
        try Data("nef".utf8).write(to: nef)
        try Data("cr3".utf8).write(to: cr3)
        let first = try item(
            id: "IMG_0001.NEF",
            url: nef,
            decision: .yes,
            stars: .five,
            color: .green
        )
        let second = try item(
            id: "IMG_0001.CR3",
            url: cr3,
            decision: .no,
            stars: .two,
            color: .red
        )
        let input = try XMPPublicationInput(
            items: [first, second],
            sessionGeneration: 1,
            profile: .captureOne,
            visibleDecisionKeywords: true
        )
        let maybePlan = await XMPPublicationPlanner.preflight(
            input,
            isCancelled: { false },
            progress: { _, _ in }
        )
        let plan = try XCTUnwrap(maybePlan)
        XCTAssertTrue(plan.resolvableSameStemConflicts.isEmpty)
        XCTAssertEqual(
            plan.entries.only?.sameStemConflict?.resolutionEligibility,
            .ineligible(.unsupportedMembers)
        )
    }

    func testRAWWinnerCopiesAllChangedValuesAndUndoRestoresOneSnapshot() async throws {
        let oldDate = Date(timeIntervalSince1970: 100)
        let fixture = try makePair(
            named: "RAWResolution",
            rawMetadata: (.yes, .five, .green),
            jpegMetadata: (.yes, .two, .red),
            rawChangedAt: Date(timeIntervalSince1970: 50),
            jpegChangedAt: oldDate
        )
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = SessionStore()
        store.items = [fixture.rawItem, fixture.jpegItem]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()

        let conflict = try await descriptor(
            selected: [fixture.rawItem],
            context: [fixture.rawItem, fixture.jpegItem],
            generation: store.xmpConflictSessionGeneration
        )
        let beforeRAW = fixture.rawItem.primaryFile.metadataSnapshot
        let beforeJPEG = fixture.jpegItem.primaryFile.metadataSnapshot
        let outcome = store.applyXMPConflictResolutions([
            XMPConflictResolutionRequest(
                conflict: conflict,
                choice: .useRAW
            )
        ])

        XCTAssertEqual(outcome.appliedCount, 1)
        let afterRAW = fixture.rawItem.primaryFile.metadataSnapshot
        let afterJPEG = fixture.jpegItem.primaryFile.metadataSnapshot
        XCTAssertEqual(afterRAW, beforeRAW)
        XCTAssertEqual(afterJPEG.rating, .yes)
        XCTAssertEqual(afterJPEG.ratedAt, beforeJPEG.ratedAt)
        XCTAssertEqual(afterJPEG.starRating, .five)
        XCTAssertEqual(afterJPEG.colorLabel, .green)
        XCTAssertGreaterThan(afterJPEG.starsChangedAt ?? .distantPast, oldDate)
        XCTAssertGreaterThan(afterJPEG.colorChangedAt ?? .distantPast, oldDate)
        XCTAssertTrue(store.canUndo)

        let replacementPlan = try await XMPExportPlanner.prepare(
            selected: store.items,
            familyContextItems: store.items,
            sessionGeneration: store.xmpConflictSessionGeneration,
            profile: .captureOne,
            visibleDecisionKeywords: true,
            allowExternalLabelReplacement: false
        )
        XCTAssertEqual(
            replacementPlan.count(.sameStemMetadataConflict),
            0
        )
        XCTAssertEqual(replacementPlan.count(.create), 1)

        store.undo()
        XCTAssertEqual(
            fixture.jpegItem.primaryFile.metadataSnapshot,
            beforeJPEG
        )
        XCTAssertEqual(fixture.rawItem.primaryFile.metadataSnapshot, beforeRAW)
    }

    func testChangedSnapshotIsRejectedWithoutOverwritingNewerMetadata() async throws {
        let fixture = try makePair(
            named: "StaleResolution",
            rawMetadata: (.yes, .five, .green),
            jpegMetadata: (.no, .two, .red)
        )
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = SessionStore()
        store.items = [fixture.rawItem, fixture.jpegItem]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        let conflict = try await descriptor(
            selected: [fixture.rawItem],
            context: [fixture.rawItem, fixture.jpegItem],
            generation: store.xmpConflictSessionGeneration
        )

        fixture.jpegItem.primaryFile.setStars(.four, changedAt: Date())
        let newer = fixture.jpegItem.primaryFile.metadataSnapshot
        let outcome = store.applyXMPConflictResolutions([
            XMPConflictResolutionRequest(
                conflict: conflict,
                choice: .useRAW
            )
        ])

        XCTAssertEqual(outcome.staleConflictIDs, [conflict.id])
        XCTAssertEqual(fixture.jpegItem.primaryFile.metadataSnapshot, newer)
        XCTAssertFalse(store.canUndo)
    }

    func testSeveralRAWAndJPEGChoicesFormOneUndoStep() async throws {
        let first = try makePair(
            named: "BatchRAW",
            rawMetadata: (.yes, .five, .green),
            jpegMetadata: (.no, .two, .red)
        )
        let second = try makePair(
            named: "BatchJPEG",
            rawMetadata: (.no, .one, .purple),
            jpegMetadata: (.yes, .four, .blue)
        )
        defer {
            try? FileManager.default.removeItem(at: first.folder)
            try? FileManager.default.removeItem(at: second.folder)
        }
        let allItems = [
            first.rawItem, first.jpegItem,
            second.rawItem, second.jpegItem,
        ]
        let store = SessionStore()
        store.items = allItems
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        let before = Dictionary(uniqueKeysWithValues: allItems.map {
            ($0.id, $0.primaryFile.metadataSnapshot)
        })

        let input = try XMPPublicationInput(
            items: [first.rawItem, second.jpegItem],
            familyContextItems: allItems,
            sessionGeneration: store.xmpConflictSessionGeneration,
            profile: .captureOne,
            visibleDecisionKeywords: true
        )
        let maybePlan = await XMPPublicationPlanner.preflight(
            input,
            isCancelled: { false },
            progress: { _, _ in }
        )
        let plan = try XCTUnwrap(maybePlan)
        XCTAssertEqual(plan.resolvableSameStemConflicts.count, 2)
        let firstFolderPath = try XMPExactFileSystemPath(url: first.folder)
        let secondFolderPath = try XMPExactFileSystemPath(url: second.folder)
        let rawChoice = try XCTUnwrap(
            plan.resolvableSameStemConflicts.first(where: {
                $0.rawMember?.exactPath.parent == firstFolderPath
            })
        )
        let jpegChoice = try XCTUnwrap(
            plan.resolvableSameStemConflicts.first(where: {
                $0.jpegMember?.exactPath.parent == secondFolderPath
            })
        )

        let outcome = store.applyXMPConflictResolutions([
            .init(conflict: rawChoice, choice: .useRAW),
            .init(conflict: jpegChoice, choice: .useJPEG),
        ])
        XCTAssertEqual(outcome.appliedCount, 2)
        XCTAssertEqual(
            first.jpegItem.primaryFile.metadataSnapshot.starRating,
            .five
        )
        XCTAssertEqual(
            second.rawItem.primaryFile.metadataSnapshot.starRating,
            .four
        )

        store.undo()
        for item in allItems {
            XCTAssertEqual(
                item.primaryFile.metadataSnapshot,
                try XCTUnwrap(before[item.id])
            )
        }
        XCTAssertFalse(store.canUndo)
    }

    private func descriptor(
        selected: [PhotoItem],
        context: [PhotoItem],
        generation: UInt64
    ) async throws -> XMPSameStemConflictDescriptor {
        let input = try XMPPublicationInput(
            items: selected,
            familyContextItems: context,
            sessionGeneration: generation,
            profile: .captureOne,
            visibleDecisionKeywords: true
        )
        let maybePlan = await XMPPublicationPlanner.preflight(
            input,
            isCancelled: { false },
            progress: { _, _ in }
        )
        let plan = try XCTUnwrap(maybePlan)
        return try XCTUnwrap(plan.resolvableSameStemConflicts.only)
    }

    private func makePair(
        named testName: String,
        rawMetadata: (Rating, StarRating?, PhotoColorLabel?),
        jpegMetadata: (Rating, StarRating?, PhotoColorLabel?),
        rawChangedAt: Date = Date(timeIntervalSince1970: 10),
        jpegChangedAt: Date = Date(timeIntervalSince1970: 20)
    ) throws -> (
        folder: URL,
        rawItem: PhotoItem,
        jpegItem: PhotoItem
    ) {
        let folder = try temporaryDirectory(named: testName)
        let raw = folder.appendingPathComponent("IMG_0001.NEF")
        let jpeg = folder.appendingPathComponent("IMG_0001.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        return (
            folder,
            try item(
                id: "\(testName)/IMG_0001.NEF",
                url: raw,
                decision: rawMetadata.0,
                stars: rawMetadata.1,
                color: rawMetadata.2,
                changedAt: rawChangedAt
            ),
            try item(
                id: "\(testName)/IMG_0001.JPG",
                url: jpeg,
                decision: jpegMetadata.0,
                stars: jpegMetadata.1,
                color: jpegMetadata.2,
                changedAt: jpegChangedAt
            )
        )
    }

    private func item(
        id: String,
        url: URL,
        decision: Rating,
        stars: StarRating?,
        color: PhotoColorLabel?,
        changedAt: Date = Date(timeIntervalSince1970: 1)
    ) throws -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(
            id: id,
            url: url,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            modificationDate: changedAt,
            fileSize: Int64((try Data(contentsOf: url)).count),
            scannedIdentity: try FileOperationJournal.captureIdentity(at: url),
            rating: decision,
            ratedAt: changedAt,
            starRating: stars,
            starsChangedAt: changedAt,
            colorLabel: color,
            colorChangedAt: changedAt
        ))
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Louppe-RAWJPEG-XMP-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
