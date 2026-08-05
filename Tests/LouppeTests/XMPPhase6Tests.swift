import Foundation
import XCTest
@testable import Louppe

final class XMPPhase6Tests: XCTestCase {
    func testCreateUpdateAndAlreadyCurrentPublication() async throws {
        let folder = try temporaryDirectory()
        let media = folder.appendingPathComponent("IMG_0001.NEF")
        try Data("raw placeholder".utf8).write(to: media)

        let initial = item(media, decision: .yes, stars: .three, color: .red)
        let createPlan = try await plan([initial], profile: .bridge)
        XCTAssertEqual(createPlan.count(.create), 1)
        let createResult = await publish(createPlan)
        XCTAssertEqual(createResult.created, 1)
        XCTAssertEqual(createResult.failed, 0)

        let sidecar = folder.appendingPathComponent("IMG_0001.xmp")
        let createdPacket = try Data(contentsOf: sidecar)
        try XMPFieldMapping.verify(
            packet: createdPacket,
            metadata: XMPPublicationMetadata(
                decision: .yes,
                stars: .three,
                colorLabel: .red,
                profile: .bridge
            )
        )

        let currentPlan = try await plan([initial], profile: .bridge)
        XCTAssertEqual(currentPlan.count(.alreadyCurrent), 1)
        let currentResult = await publish(currentPlan)
        XCTAssertEqual(currentResult.alreadyCurrent, 1)

        let changed = item(media, decision: .no, stars: .five, color: .blue)
        let updatePlan = try await plan([changed], profile: .bridge)
        XCTAssertEqual(updatePlan.count(.update), 1)
        XCTAssertEqual(updatePlan.changeCounts.stars, 1)
        XCTAssertEqual(updatePlan.changeCounts.colors, 1)
        XCTAssertEqual(updatePlan.changeCounts.flags, 1)
        XCTAssertEqual(updatePlan.changeCounts.keywords, 1)
        let updateResult = await publish(updatePlan)
        XCTAssertEqual(updateResult.updated, 1)
        XCTAssertEqual(updateResult.failed, 0)
    }

    func testPreflightReportsOnlyExactLightroomACRCompanions() async throws {
        let folder = try temporaryDirectory()
        let media = folder.appendingPathComponent("HEAVY.NEF")
        try Data("raw placeholder".utf8).write(to: media)
        try Data("shared heavy edits".utf8).write(
            to: folder.appendingPathComponent("HEAVY.ACR")
        )
        try Data("qualified heavy edits".utf8).write(
            to: folder.appendingPathComponent("HEAVY.NEF.acr")
        )
        try Data("unrelated".utf8).write(
            to: folder.appendingPathComponent("HEAVY-copy.acr")
        )

        let preflight = try await plan([
            item(media, decision: .yes, stars: .four, color: .blue)
        ], profile: .lightroomClassic)

        XCTAssertEqual(preflight.publishableCount, 1)
        XCTAssertEqual(preflight.excludedACRCompanionCount, 2)
        XCTAssertEqual(
            preflight.entries.first?.excludedACRCompanionCount,
            2
        )
    }

    func testSameStemDifferentPhysicalMetadataIsVisibleAndSkipped() async throws {
        let folder = try temporaryDirectory()
        let raw = folder.appendingPathComponent("PAIR.NEF")
        let jpeg = folder.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        try XMPFieldMapping.merge(
            packet: nil,
            metadata: XMPPublicationMetadata(
                decision: .yes,
                stars: .four,
                colorLabel: .green,
                profile: .captureOne
            )
        ).write(to: folder.appendingPathComponent("PAIR.xmp"))
        let pair = PhotoItem(
            primaryFile: file(raw, decision: .yes, stars: .four, color: .green),
            pairedFile: file(jpeg, decision: .no, stars: .four, color: .green)
        )

        let preflight = try await plan([pair], profile: .captureOne)
        XCTAssertEqual(preflight.count(.sameStemMetadataConflict), 1)
        XCTAssertEqual(preflight.publishableCount, 0)
        XCTAssertNotNil(preflight.entries.first?.canonicalSidecar)
        let result = await publish(preflight)
        XCTAssertEqual(result.conflicts, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("PAIR.xmp").path
            )
        )
    }

    func testUnselectedSeparateSiblingStillProtectsSharedStemSidecar() async throws {
        let folder = try temporaryDirectory()
        let raw = folder.appendingPathComponent("SPLIT.NEF")
        let jpeg = folder.appendingPathComponent("SPLIT.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let selectedRAW = item(raw, decision: .yes, stars: .five)
        let excludedJPEG = item(jpeg, decision: .no, stars: .one)

        let preflight = try await plan(
            [selectedRAW],
            familyContext: [selectedRAW, excludedJPEG],
            profile: .bridge
        )
        XCTAssertEqual(preflight.selectedItemCount, 1)
        XCTAssertEqual(preflight.physicalFileCount, 1)
        XCTAssertEqual(preflight.count(.sameStemMetadataConflict), 1)
        XCTAssertEqual(
            preflight.entries.first?.filenames,
            ["SPLIT.JPG", "SPLIT.NEF"]
        )
    }

    func testMalformedAndUnsafePacketsArePreflightFailures() async throws {
        let folder = try temporaryDirectory()
        let malformedMedia = folder.appendingPathComponent("BROKEN.NEF")
        let unsafeMedia = folder.appendingPathComponent("UNSAFE.NEF")
        try Data("raw".utf8).write(to: malformedMedia)
        try Data("raw".utf8).write(to: unsafeMedia)
        try Data("<not-xmp>".utf8).write(
            to: folder.appendingPathComponent("BROKEN.xmp")
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("UNSAFE.xmp"),
            withDestinationURL: folder.appendingPathComponent("BROKEN.xmp")
        )

        let preflight = try await plan([
            item(malformedMedia, decision: .yes),
            item(unsafeMedia, decision: .yes),
        ])
        XCTAssertEqual(preflight.count(.malformedXMP), 1)
        XCTAssertEqual(preflight.count(.unsafeFileType), 1)
        let result = await publish(preflight)
        XCTAssertEqual(result.failed, 2)
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent("BROKEN.xmp")),
            Data("<not-xmp>".utf8)
        )
    }

    func testVideoIsExcludedAndNotCountedAsAPhysicalPhoto() async throws {
        let folder = try temporaryDirectory()
        let movie = folder.appendingPathComponent("CLIP.MOV")
        try Data("movie".utf8).write(to: movie)
        try Data("video sidecar".utf8).write(
            to: folder.appendingPathComponent("CLIP.xmp")
        )
        let video = PhotoItem(primaryFile: PhotoFile(
            id: movie.lastPathComponent,
            url: movie,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: .video,
            fileSize: 5,
            rating: .yes
        ))

        let preflight = try await plan([video])
        XCTAssertEqual(preflight.selectedItemCount, 1)
        XCTAssertEqual(preflight.physicalFileCount, 0)
        XCTAssertEqual(preflight.count(.unsupportedMedia), 1)
        XCTAssertEqual(preflight.publishableCount, 0)
        XCTAssertNil(preflight.entries.first?.canonicalSidecar)
    }

    func testExternalEditAfterPreflightNeverGetsOverwritten() async throws {
        let folder = try temporaryDirectory()
        let media = folder.appendingPathComponent("RACE.NEF")
        try Data("raw".utf8).write(to: media)
        let selected = item(media, decision: .yes, stars: .two, color: .yellow)
        let preflight = try await plan([selected])
        XCTAssertEqual(preflight.count(.create), 1)

        let sidecar = folder.appendingPathComponent("RACE.xmp")
        let external = try XMPFieldMapping.merge(
            packet: nil,
            metadata: XMPPublicationMetadata(
                decision: .no,
                stars: .five,
                colorLabel: .purple,
                profile: .universal
            )
        )
        try external.write(to: sidecar)

        let result = await publish(preflight)
        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(result.created, 0)
        XCTAssertEqual(try Data(contentsOf: sidecar), external)
    }

    func testCustomExternalLabelRequiresExplicitBatchConfirmation() async throws {
        let folder = try temporaryDirectory()
        let media = folder.appendingPathComponent("CUSTOM.NEF")
        let sidecar = folder.appendingPathComponent("CUSTOM.xmp")
        try Data("raw".utf8).write(to: media)
        try fixture("universal-unknown.xmp").write(to: sidecar)
        let selected = item(media, decision: .yes, color: .red)

        let blocked = try await plan([selected])
        XCTAssertEqual(blocked.count(.externalModificationConflict), 1)
        XCTAssertTrue(blocked.entries[0].message.contains("Client Violet"))

        let confirmed = try await plan(
            [selected],
            allowExternalLabelReplacement: true
        )
        XCTAssertEqual(confirmed.count(.update), 1)
        let result = await publish(confirmed)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(
            try XMPFieldMapping.readProperty(
                namespace: XMPFieldMapping.xmpNamespace,
                path: "Label",
                packet: Data(contentsOf: sidecar)
            ),
            "Red"
        )
    }

    func testReadOnlyExistingPacketIsReportedBeforePublication() async throws {
        let folder = try temporaryDirectory()
        let media = folder.appendingPathComponent("READ_ONLY.NEF")
        let sidecar = folder.appendingPathComponent("READ_ONLY.xmp")
        try Data("raw".utf8).write(to: media)
        let packet = try XMPFieldMapping.merge(
            packet: nil,
            metadata: XMPPublicationMetadata(
                decision: .no,
                stars: .one,
                colorLabel: nil,
                profile: .universal
            )
        )
        try packet.write(to: sidecar)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: sidecar.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: sidecar.path
            )
        }

        let current = try await plan([
            item(media, decision: .no, stars: .one)
        ])
        XCTAssertEqual(current.count(.alreadyCurrent), 1)

        let preflight = try await plan([
            item(media, decision: .yes, stars: .five)
        ])
        XCTAssertEqual(preflight.count(.readOnlyPermissionFailure), 1)
        XCTAssertEqual(preflight.publishableCount, 0)
        XCTAssertEqual(try Data(contentsOf: sidecar), packet)
    }

    func testCancellationBeforeWorkLeavesEverySidecarAbsent() async throws {
        let folder = try temporaryDirectory()
        let items = try (0..<20).map { index in
            let media = folder.appendingPathComponent("CANCEL_\(index).NEF")
            try Data("raw".utf8).write(to: media)
            return item(media, decision: .yes, stars: .one)
        }
        let preflight = try await plan(items)
        let cancel = XMPPublicationCancelFlag()
        cancel.set()
        let result = await XMPPublicationWorker.publish(
            preflight,
            cancelFlag: cancel
        ) { _, _ in }
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "xmp" }.count,
            0
        )
    }

    func testCancellationDuringBatchStopsBetweenAtomicPackets() async throws {
        let folder = try temporaryDirectory()
        let items = try (0..<30).map { index in
            let media = folder.appendingPathComponent("BOUNDARY_\(index).NEF")
            try Data("raw".utf8).write(to: media)
            return item(media, decision: .yes, stars: .two, color: .green)
        }
        let preflight = try await plan(items, profile: .bridge)
        let cancel = XMPPublicationCancelFlag()
        let result = await XMPPublicationWorker.publish(
            preflight,
            cancelFlag: cancel
        ) { done, _ in
            if done >= 1 { cancel.set() }
        }
        XCTAssertTrue(result.cancelled)
        XCTAssertGreaterThanOrEqual(result.completed, 1)
        XCTAssertLessThan(result.completed, 30)

        let sidecars = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "xmp" }
        XCTAssertEqual(sidecars.count, result.created)
        for sidecar in sidecars {
            try XMPFieldMapping.verify(
                packet: Data(contentsOf: sidecar),
                metadata: XMPPublicationMetadata(
                    decision: .yes,
                    stars: .two,
                    colorLabel: .green,
                    profile: .bridge
                )
            )
        }
    }

    @MainActor
    func testSessionLifecycleOwnsPreflightAndCancellation() async throws {
        let folder = try temporaryDirectory()
        let media = folder.appendingPathComponent("SESSION.NEF")
        try Data("raw".utf8).write(to: media)
        let selected = item(media, decision: .yes)
        let store = SessionStore()
        store.items = [selected]
        store.phase = .ready

        store.prepareXMPPublication(
            selected: [selected],
            profile: .universal,
            visibleDecisionKeywords: false
        )
        await waitUntil {
            if case .awaitingConfirmation = store.xmpPublicationState {
                return true
            }
            return false
        }
        guard case .awaitingConfirmation(let plan) = store.xmpPublicationState else {
            return XCTFail("Preflight did not reach confirmation")
        }
        store.startXMPPublication(planID: plan.id)
        await store.cancelAndAwaitXMPPublication()
        XCTAssertEqual(store.xmpPublicationState, .idle)
        XCTAssertFalse(store.isXMPPublicationRunning)
    }

    private func plan(
        _ items: [PhotoItem],
        familyContext: [PhotoItem]? = nil,
        profile: XMPApplicationProfile = .universal,
        allowExternalLabelReplacement: Bool = false
    ) async throws -> XMPPublicationPlan {
        let input = try XMPPublicationInput(
            items: items,
            familyContextItems: familyContext,
            profile: profile,
            visibleDecisionKeywords: profile.usesVisibleDecisionKeywordsByDefault,
            allowExternalLabelReplacement: allowExternalLabelReplacement
        )
        let result = await XMPPublicationPlanner.preflight(
            input,
            isCancelled: { false }
        ) { _, _ in }
        return try XCTUnwrap(result)
    }

    private func publish(_ plan: XMPPublicationPlan) async -> XMPPublicationResult {
        await XMPPublicationWorker.publish(
            plan,
            cancelFlag: XMPPublicationCancelFlag()
        ) { _, _ in }
    }

    private func item(
        _ url: URL,
        decision: Rating,
        stars: StarRating? = nil,
        color: PhotoColorLabel? = nil
    ) -> PhotoItem {
        PhotoItem(primaryFile: file(
            url,
            decision: decision,
            stars: stars,
            color: color
        ))
    }

    private func file(
        _ url: URL,
        decision: Rating,
        stars: StarRating? = nil,
        color: PhotoColorLabel? = nil
    ) -> PhotoFile {
        PhotoFile(
            id: url.lastPathComponent,
            url: url,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1,
            rating: decision,
            starRating: stars,
            colorLabel: color
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "louppe-xmp-phase6-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
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

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
