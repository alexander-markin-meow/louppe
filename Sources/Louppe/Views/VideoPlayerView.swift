import SwiftUI
import AVKit

/// Full native macOS player used by the Gallery. AVPlayerView supplies the
/// transport bar, scrubber, volume, time, Picture in Picture and full screen.
struct GalleryVideoPlayerView: View {
    let item: PhotoItem
    @ObservedObject var playback: VideoPlaybackController

    var body: some View {
        Group {
            if !item.videoIsPlayable {
                unsupportedView
            } else if let error = playback.errorMessage, playback.itemID == item.id {
                ContentUnavailableView(
                    "Can't play this video",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                NativeVideoPlayer(player: playback.player, controls: .full)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { playback.prepare(item) }
        .onChange(of: item.id) { playback.prepare(item) }
    }

    private var unsupportedView: some View {
        ContentUnavailableView(
            "Video isn't supported",
            systemImage: "film",
            description: Text("macOS can't play this video's container or codec. You can still rate and export it — \(item.displayName)")
        )
    }
}

enum NativeVideoControls {
    case full
    case none
}

/// AppKit bridge used for both Gallery and Grid so playback stays entirely on
/// macOS's AVKit/AVFoundation stack.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    let controls: NativeVideoControls

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        Self.configure(view, player: player, controls: controls)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        Self.configure(view, player: player, controls: controls)
    }

    /// Keep configuration idempotent: resetting AVKit's controls style during
    /// every SwiftUI update causes its secondary buttons to animate and shift.
    static func configure(
        _ view: AVPlayerView,
        player: AVPlayer,
        controls: NativeVideoControls
    ) {
        if view.player !== player { view.player = player }
        view.videoGravity = .resizeAspect
        switch controls {
        case .full:
            // Apple's default inline pane stays anchored while player items
            // change. AVKit still switches to floating controls in fullscreen.
            if view.controlsStyle != .inline { view.controlsStyle = .inline }
            view.showsFullScreenToggleButton = true
            view.showsFrameSteppingButtons = true
            view.allowsPictureInPicturePlayback = true
        case .none:
            if view.controlsStyle != .none { view.controlsStyle = .none }
            view.showsFullScreenToggleButton = false
            view.showsFrameSteppingButtons = false
            view.allowsPictureInPicturePlayback = false
        }
    }
}
