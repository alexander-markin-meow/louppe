import XCTest
@testable import Louppe

@MainActor
final class BrowserSelectionTests: XCTestCase {
    func testDeletingCurrentItemSelectsSuccessorAtSameIndex() {
        let store = SessionStore()
        store.items = (0..<3).map { index in
            let id = "VIDEO_\(index).MOV"
            return PhotoItem(
                id: id,
                primaryURL: URL(fileURLWithPath: "/tmp/\(id)"),
                pairedURL: nil,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                mediaKind: .video,
                duration: 2,
                videoIsPlayable: true,
                fileSize: 1
            )
        }
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        store.setIndex(1)
        let removedID = store.currentItem!.id
        let successorID = store.items[2].id

        store.exportMoveWillStart()
        store.finishExportMove(movedIDs: [removedID])

        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.currentItem?.id, successorID)
        XCTAssertTrue(store.visibleIndices.contains(store.currentIndex))
    }
}
