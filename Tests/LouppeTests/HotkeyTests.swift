import AppKit
import XCTest
@testable import Louppe

@MainActor
final class HotkeyTests: XCTestCase {
    func testArrowKeysNavigateGridEvenWhenCurrentItemIsVideo() {
        let store = readyStore(itemCount: 6, firstItemIsVideo: true)
        store.viewMode = .grid
        store.setGridColumnCount(3)
        let view = SessionView(store: store)

        XCTAssertTrue(view.handleKey(keyEvent(code: 124))) // right
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(view.handleKey(keyEvent(code: 125))) // down
        XCTAssertEqual(store.currentIndex, 4)
        XCTAssertTrue(view.handleKey(keyEvent(code: 126))) // up
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(view.handleKey(keyEvent(code: 123))) // left
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testReviewHotkeysStillRateAndAdvance() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: true)
        let view = SessionView(store: store)

        XCTAssertTrue(view.handleKey(keyEvent(code: 3, characters: "f")))
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)

        XCTAssertTrue(view.handleKey(keyEvent(code: 2, characters: "d")))
        XCTAssertEqual(store.items[1].rating, .no)
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testSpaceTogglesVideoButAdvancesFromPhoto() {
        let videoStore = readyStore(itemCount: 3, firstItemIsVideo: true)
        let videoView = SessionView(store: videoStore)

        XCTAssertTrue(videoView.handleKey(keyEvent(code: 49, characters: " ")))
        XCTAssertEqual(videoStore.currentIndex, 0)
        XCTAssertEqual(videoStore.videoPlayback.itemID, videoStore.items[0].id)
        XCTAssertTrue(videoStore.videoPlayback.isActive(videoStore.items[0]))

        let photoStore = readyStore(itemCount: 3, firstItemIsVideo: false)
        let photoView = SessionView(store: photoStore)

        XCTAssertTrue(photoView.handleKey(keyEvent(code: 49, characters: " ")))
        XCTAssertEqual(photoStore.currentIndex, 1)
        XCTAssertNil(photoStore.videoPlayback.itemID)
    }

    private func readyStore(itemCount: Int, firstItemIsVideo: Bool) -> SessionStore {
        _ = NSApplication.shared
        let store = SessionStore()
        store.items = (0..<itemCount).map { index in
            let isVideo = firstItemIsVideo && index == 0
            let ext = isVideo ? "MOV" : "JPG"
            let id = "ITEM_\(index).\(ext)"
            return PhotoItem(
                id: id,
                primaryURL: URL(fileURLWithPath: "/tmp/\(id)"),
                pairedURL: nil,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                mediaKind: isVideo ? .video : .photo,
                duration: isVideo ? 2 : nil,
                videoIsPlayable: isVideo,
                fileSize: 1
            )
        }
        // A sort change rebuilds the same visibility structures populated by
        // a real folder scan, while keeping the test independent of disk I/O.
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        return store
    }

    private func keyEvent(code: UInt16, characters: String = "") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }
}
