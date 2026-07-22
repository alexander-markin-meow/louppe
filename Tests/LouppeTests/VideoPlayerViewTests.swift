import AVKit
import XCTest
@testable import Louppe

@MainActor
final class VideoPlayerViewTests: XCTestCase {
    func testGalleryPlayerUsesStableNativeInlineControls() {
        let view = AVPlayerView()
        let player = AVPlayer()

        NativeVideoPlayer.configure(view, player: player, controls: .full)

        XCTAssertTrue(view.player === player)
        XCTAssertEqual(view.controlsStyle, .inline)
        XCTAssertTrue(view.showsFullScreenToggleButton)
        XCTAssertTrue(view.showsFrameSteppingButtons)
        XCTAssertTrue(view.allowsPictureInPicturePlayback)

        // Reapplying the same SwiftUI configuration must keep the native view
        // and its anchored controls unchanged.
        NativeVideoPlayer.configure(view, player: player, controls: .full)
        XCTAssertTrue(view.player === player)
        XCTAssertEqual(view.controlsStyle, .inline)
    }
}
