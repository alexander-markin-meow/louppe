import Foundation
import AVFoundation

/// One native player per session. Grid and Gallery attach different native
/// views to it, preserving position when the user switches view modes while
/// ensuring two videos can never play at once.
@MainActor
final class VideoPlaybackController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var itemID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?

    init() {
        player.actionAtItemEnd = .pause
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    func prepare(_ item: PhotoItem) {
        guard item.isVideo else { return }
        if itemID == item.id, player.currentItem != nil { return }
        stop()
        itemID = item.id
        errorMessage = nil
        guard item.videoIsPlayable else {
            errorMessage = "This video's format or codec isn't supported by macOS."
            return
        }

        let playerItem = AVPlayerItem(url: item.primaryURL)
        player.replaceCurrentItem(with: playerItem)
        observe(playerItem, itemID: item.id)
    }

    func toggle(_ item: PhotoItem) {
        prepare(item)
        guard player.currentItem != nil, errorMessage == nil else { return }
        if isPlaying {
            pause()
        } else {
            if let duration = player.currentItem?.duration.seconds,
               duration.isFinite,
               player.currentTime().seconds >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        pause()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        itemID = nil
        errorMessage = nil
    }

    func isActive(_ item: PhotoItem) -> Bool {
        itemID == item.id && player.currentItem != nil
    }

    private func observe(_ playerItem: AVPlayerItem, itemID observedID: String) {
        removeObservers()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.itemID == observedID else { return }
                self?.isPlaying = false
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard self?.itemID == observedID else { return }
                self?.isPlaying = false
                self?.errorMessage = message ?? "The video couldn't be played."
            }
        }
        itemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The video couldn't be played."
            Task { @MainActor in
                guard self?.itemID == observedID else { return }
                self?.isPlaying = false
                self?.errorMessage = message
            }
        }
    }

    private func removeObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        itemStatusObservation = nil
    }
}
