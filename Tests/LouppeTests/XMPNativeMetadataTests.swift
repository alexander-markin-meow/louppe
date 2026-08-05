import Combine
import XCTest
@testable import Louppe

@MainActor
final class XMPNativeMetadataTests: XCTestCase {
    func testPairProjectsEachMetadataDimensionIndependently() {
        let raw = makeFile(
            id: "PAIR.NEF",
            decision: .yes,
            stars: .four,
            color: .red
        )
        let jpeg = makeFile(
            id: "PAIR.JPG",
            decision: .yes,
            stars: .two,
            color: .red
        )
        let item = PhotoItem(primaryFile: raw, pairedFile: jpeg)

        XCTAssertEqual(item.ratingState, .yes)
        XCTAssertEqual(item.starRatingState, .mixed)
        XCTAssertEqual(item.colorLabelState, .label(.red))

        item.setStars(.five, changedAt: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(item.ratingState, .yes)
        XCTAssertEqual(item.starRatingState, .stars(.five))
        XCTAssertEqual(item.colorLabelState, .label(.red))
        XCTAssertEqual(item.metadataSnapshots.map(\.starRating), [.five, .five])
    }

    func testStoreMutationsAndUndoAreDimensionSpecific() {
        let store = SessionStore()
        store.items = [
            PhotoItem(primaryFile: makeFile(id: "A.JPG", decision: .yes))
        ]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready

        store.setStarRating(.three)
        XCTAssertEqual(store.starCount(.three), 1)
        XCTAssertEqual(store.unratedStarCount, 0)
        XCTAssertEqual(store.items[0].rating, .yes)

        store.setColorLabel(.purple)
        XCTAssertEqual(store.colorCount(.purple), 1)
        XCTAssertEqual(store.items[0].starRatingState, .stars(.three))

        store.undo()
        XCTAssertEqual(store.items[0].colorLabelState, .none)
        XCTAssertEqual(store.items[0].starRatingState, .stars(.three))
        XCTAssertEqual(store.items[0].rating, .yes)

        store.undo()
        XCTAssertEqual(store.items[0].starRatingState, .unrated)
        XCTAssertEqual(store.items[0].rating, .yes)
    }

    func testMetadataPublicationExposesTheNewLockedSnapshot() {
        let store = SessionStore()
        store.items = [PhotoItem(primaryFile: makeFile(id: "A.JPG"))]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready

        var publishedDecisions: [PhotoItemRatingState] = []
        var publishedStars: [PhotoItemStarRatingState] = []
        var publishedColors: [PhotoItemColorLabelState] = []
        let subscription = store.objectWillChange.sink {
            publishedDecisions.append(store.items[0].ratingState)
            publishedStars.append(store.items[0].starRatingState)
            publishedColors.append(store.items[0].colorLabelState)
        }
        defer { subscription.cancel() }

        store.rate(.yes, at: 0)
        XCTAssertEqual(publishedDecisions.last, .yes)

        store.setStarRating(.two)
        XCTAssertEqual(publishedStars.last, .stars(.two))

        store.setColorLabel(.red)
        XCTAssertEqual(publishedColors.last, .label(.red))
    }

    func testSchemaFiveUsesStarsKeyAndLegacyEntryDefaultsToNil() throws {
        let entry = SessionEntry(
            filename: "A.JPG",
            pairedFilename: nil,
            rating: Rating.yes.rawValue,
            ratedAt: nil,
            stars: .four,
            colorLabel: .purple
        )
        let encoded = try JSONEncoder().encode(entry)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["stars"] as? Int, 4)
        XCTAssertNil(object["starRating"])
        XCTAssertEqual(object["colorLabel"] as? String, "purple")

        let legacy = Data(
            #"{"filename":"OLD.JPG","rating":"no","ratedAt":null}"#.utf8
        )
        let decoded = try JSONDecoder().decode(SessionEntry.self, from: legacy)
        XCTAssertNil(decoded.stars)
        XCTAssertNil(decoded.colorLabel)
    }

    func testInvalidStarsAndColorsFailInsteadOfBeingCoerced() {
        let invalidStars = Data(
            #"{"filename":"A.JPG","rating":"yes","stars":6}"#.utf8
        )
        let invalidColor = Data(
            #"{"filename":"A.JPG","rating":"yes","colorLabel":"orange"}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionEntry.self, from: invalidStars)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionEntry.self, from: invalidColor)
        )
    }

    func testLegacySchemaCannotAdoptSchemaFiveMetadataKeys() {
        let legacy = SessionFile(
            version: 1,
            sourcePath: "/tmp",
            scannedAt: Date(),
            entries: [SessionEntry(
                filename: "A.JPG",
                pairedFilename: nil,
                rating: Rating.yes.rawValue,
                ratedAt: nil,
                stars: .five,
                starsChangedAt: Date(),
                colorLabel: .red,
                colorChangedAt: Date()
            )]
        )
        let file = makeFile(id: "A.JPG")

        let restored = SessionRatingIndex(session: legacy).value(for: file)

        XCTAssertEqual(restored?.rating, .yes)
        XCTAssertNil(restored?.starRating)
        XCTAssertNil(restored?.starsChangedAt)
        XCTAssertNil(restored?.colorLabel)
        XCTAssertNil(restored?.colorChangedAt)
    }

    func testSchemaFiveMetadataSurvivesSaveAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-XMP-Native-\(UUID().uuidString)",
            isDirectory: true
        )
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: photos.appendingPathComponent("A.png"))

        let persistence = SessionPersistence(backupDirectory: backup)
        let store = SessionStore(
            persistence: persistence,
            saveTrailingDelay: 0.01,
            saveMaximumDelay: 0.02
        )
        store.openFolder(photos)
        try await waitForReady(store)
        store.setStarRating(.four)
        store.setColorLabel(.blue)

        let saved = try await waitForSidecar(in: photos) { session in
            session.version == 5
                && session.entries.first?.stars == .four
                && session.entries.first?.colorLabel == .blue
        }
        XCTAssertNotNil(saved.entries.first?.starsChangedAt)
        XCTAssertNotNil(saved.entries.first?.colorChangedAt)
        let firstStoreBecameIdle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(
            firstStoreBecameIdle,
            "the first store should release its folder-lineage lock before reopen"
        )

        let reopened = SessionStore(
            persistence: SessionPersistence(backupDirectory: backup)
        )
        reopened.openFolder(photos)
        try await waitForReady(reopened)
        XCTAssertEqual(reopened.items.first?.starRatingState, .stars(.four))
        XCTAssertEqual(reopened.items.first?.colorLabelState, .label(.blue))
    }

    private func makeFile(
        id: String,
        decision: Rating = .undecided,
        stars: StarRating? = nil,
        color: PhotoColorLabel? = nil
    ) -> PhotoFile {
        PhotoFile(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id)"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 10,
            rating: decision,
            starRating: stars,
            colorLabel: color
        )
    }

    private func waitForReady(_ store: SessionStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if case .ready = store.phase, store.items.count == 1 { return }
            guard ContinuousClock.now < deadline else {
                XCTFail("session did not become ready")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForSidecar(
        in folder: URL,
        matching predicate: (SessionFile) -> Bool
    ) async throws -> SessionFile {
        let sidecar = folder.appendingPathComponent(SessionConstants.sidecarName)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: sidecar),
               let session = try? decoder.decode(SessionFile.self, from: data),
               predicate(session) {
                return session
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "XMPNativeMetadataTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "schema-5 sidecar was not saved"]
        )
    }
}
