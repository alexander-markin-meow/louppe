import Foundation
import AVFoundation

/// NotificationCenter's opaque observer token is not Sendable, while a
/// main-actor class's deinitializer is nonisolated. Keep each token behind a
/// lock-protected Sendable owner so cleanup is valid from either boundary.
private final class NotificationObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func replace(with newToken: NSObjectProtocol) {
        lock.lock()
        let oldToken = token
        token = newToken
        lock.unlock()
        if let oldToken { NotificationCenter.default.removeObserver(oldToken) }
    }

    func remove() {
        lock.lock()
        let oldToken = token
        token = nil
        lock.unlock()
        if let oldToken { NotificationCenter.default.removeObserver(oldToken) }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// One native player per session. Grid and Gallery attach different native
/// views to it, preserving position when the user switches view modes while
/// ensuring two videos can never play at once.
@MainActor
final class VideoPlaybackController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var itemID: String?
    @Published private(set) var contentRevision: PhotoContentRevision?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private let endObserver = NotificationObserverBox()
    private let failureObserver = NotificationObserverBox()
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    /// A content revision can recur after A → B → A navigation. Advancing a
    /// separate generation prevents a Task queued by the first A player item
    /// from mutating the replacement A item when it eventually reaches the
    /// main actor.
    private var playbackGeneration: UInt64 = 0

    init() {
        player.actionAtItemEnd = .pause
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    deinit {
        endObserver.remove()
        failureObserver.remove()
    }

    func prepare(_ item: PhotoItem) {
        guard item.isVideo else { return }
        let requestedRevision = item.contentRevision
        if contentRevision == requestedRevision,
           player.currentItem != nil { return }
        stop()
        itemID = item.id
        contentRevision = requestedRevision
        errorMessage = nil
        guard item.videoIsPlayable else {
            errorMessage = "This video's format or codec isn't supported by macOS."
            return
        }

        let playerItem = AVPlayerItem(url: item.primaryURL)
        player.replaceCurrentItem(with: playerItem)
        observe(
            playerItem,
            contentRevision: requestedRevision,
            generation: playbackGeneration
        )
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
        playbackGeneration &+= 1
        pause()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        itemID = nil
        contentRevision = nil
        errorMessage = nil
    }

    func isActive(_ item: PhotoItem) -> Bool {
        represents(item) && player.currentItem != nil
    }

    func represents(_ item: PhotoItem) -> Bool {
        itemID == item.id && contentRevision == item.contentRevision
    }

    private func observe(
        _ playerItem: AVPlayerItem,
        contentRevision observedRevision: PhotoContentRevision,
        generation observedGeneration: UInt64
    ) {
        removeObservers()
        endObserver.replace(with: NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.playbackGeneration == observedGeneration,
                      self?.contentRevision == observedRevision else { return }
                self?.isPlaying = false
            }
        })
        failureObserver.replace(with: NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard self?.playbackGeneration == observedGeneration,
                      self?.contentRevision == observedRevision else { return }
                self?.isPlaying = false
                self?.errorMessage = message ?? "The video couldn't be played."
            }
        })
        itemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The video couldn't be played."
            Task { @MainActor in
                guard self?.playbackGeneration == observedGeneration,
                      self?.contentRevision == observedRevision else { return }
                self?.isPlaying = false
                self?.errorMessage = message
            }
        }
    }

    private func removeObservers() {
        endObserver.remove()
        failureObserver.remove()
        itemStatusObservation = nil
    }
}
