import XCTest
@testable import Louppe

@MainActor
final class AccessibilityTests: XCTestCase {
    func testMediaTileDescriptionIncludesNonvisualState() {
        let item = mixedPair()

        XCTAssertEqual(
            MediaTileAccessibility.value(
                for: item,
                isCurrent: true,
                isSelected: true
            ),
            "RAW and JPEG photo, Mixed decision, No stars, No color label, Current item, Selected"
        )
    }

    func testUnavailableRatingActionsAreOmittedFromVoiceOver() {
        XCTAssertEqual(
            MediaTileAccessibility.ratingActions(canRate: true),
            [.yes, .no, .clear]
        )
        XCTAssertTrue(
            MediaTileAccessibility.ratingActions(canRate: false).isEmpty
        )
        XCTAssertTrue(
            MediaTileAccessibility.actionHint(canRate: true)
                .contains("stars")
        )
        XCTAssertFalse(
            MediaTileAccessibility.actionHint(canRate: false)
                .contains("stars")
        )
    }

    func testExplicitTileRatingUpdatesPairAndUndoRestoresConflict() {
        let store = SessionStore()
        store.items = [mixedPair()]
        // Rebuild the same stable file-ID map populated by a folder scan.
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready

        store.rate(.yes, at: 0)

        XCTAssertEqual(
            store.items[0].ratingSnapshots.map(\.rating),
            [.yes, .yes]
        )
        XCTAssertFalse(store.items[0].hasMixedRatings)

        store.undo()

        XCTAssertEqual(
            store.items[0].ratingSnapshots.map(\.rating),
            [.yes, .no]
        )
        XCTAssertTrue(store.items[0].hasMixedRatings)
    }

    private func mixedPair() -> PhotoItem {
        let raw = PhotoFile(
            id: "SHOT.NEF",
            url: URL(fileURLWithPath: "/tmp/SHOT.NEF"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 10,
            rating: .yes
        )
        let jpeg = PhotoFile(
            id: "SHOT.JPG",
            url: URL(fileURLWithPath: "/tmp/SHOT.JPG"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 5,
            rating: .no
        )
        return PhotoItem(primaryFile: raw, pairedFile: jpeg)
    }
}
