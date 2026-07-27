import XCTest
@testable import Louppe

@MainActor
final class SelectionStateTests: XCTestCase {
    func testRangeSelectionDropsMembersHiddenByFilter() {
        let store = readyStore()
        store.setIndex(1)
        store.selectRange(to: 3)
        XCTAssertEqual(store.selectedIndices, [1, 2, 3])

        store.filter.excludedTypes = ["PNG"]

        XCTAssertEqual(store.visibleIndices, [0, 2])
        XCTAssertEqual(store.selectedIndices, [2])
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testTogglingCurrentMovesAnchorToSurvivingSelection() {
        let store = readyStore()
        store.setIndex(1)

        store.toggleSelection(of: 3)
        XCTAssertEqual(store.selectedIndices, [1, 3])
        XCTAssertEqual(store.currentIndex, 1)

        store.toggleSelection(of: 1)
        XCTAssertEqual(store.selectedIndices, [3])
        XCTAssertEqual(store.currentIndex, 3)
    }

    func testBatchRatingAndUndoKeepSelectionAndIdentityRules() {
        let store = readyStore()
        store.selectRange(to: 2)

        store.rate(.yes)

        XCTAssertEqual(store.items.prefix(3).map(\.rating), [.yes, .yes, .yes])
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(store.currentIndex, 3)

        store.undo()

        XCTAssertEqual(
            store.items.prefix(3).map(\.rating),
            [.undecided, .undecided, .undecided]
        )
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testZeroMatchFilterHasNoImplicitSelection() {
        let store = readyStore()
        store.filter.excludedTypes = ["JPEG", "PNG"]

        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertTrue(store.effectiveSelection.isEmpty)

        store.rate(.no)

        XCTAssertTrue(store.items.allSatisfy { $0.rating == .undecided })
    }

    private func readyStore() -> SessionStore {
        let store = SessionStore()
        store.items = [
            makeItem("A.JPG"),
            makeItem("B.PNG"),
            makeItem("C.JPG"),
            makeItem("D.PNG"),
        ]
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        return store
    }

    private func makeItem(_ id: String) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: URL(fileURLWithPath: "/tmp/\(id)"),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
    }
}
