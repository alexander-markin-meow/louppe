import Foundation
import AVFoundation
import CoreMedia

/// Scan-cached information for a movie. Asset loading happens only from the
/// folder scanner's bounded background workers; views never probe movie files.
struct VideoScanInfo: Sendable {
    let duration: TimeInterval?
    let dimensions: CGSize?
    let codec: String?
    let frameRate: Double?
    let isPlayable: Bool
}

enum VideoMetadataExtractor {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: VideoScanInfo?

        func store(_ value: VideoScanInfo) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> VideoScanInfo? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func scanInfo(for url: URL) -> VideoScanInfo {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            box.store(await loadScanInfo(for: url))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            task.cancel()
            return unavailable
        }
        return box.load() ?? unavailable
    }

    /// FolderScanner owns synchronous bounded workers. This async inner load
    /// uses AVFoundation's current APIs, while the small semaphore bridge
    /// above keeps those workers bounded and prevents main-actor I/O.
    private static func loadScanInfo(for url: URL) async -> VideoScanInfo {
        let asset = AVURLAsset(url: url)
        do {
            async let loadedDuration = asset.load(.duration)
            async let loadedPlayable = asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let durationSeconds = try await loadedDuration.seconds
            let duration = durationSeconds.isFinite && durationSeconds >= 0 ? durationSeconds : nil
            guard let track = tracks.first else {
                return VideoScanInfo(
                    duration: duration,
                    dimensions: nil,
                    codec: nil,
                    frameRate: nil,
                    isPlayable: false
                )
            }

            async let naturalSize = track.load(.naturalSize)
            async let transform = track.load(.preferredTransform)
            async let nominalFrameRate = track.load(.nominalFrameRate)
            async let descriptions = track.load(.formatDescriptions)
            let size = try await naturalSize
            let preferredTransform = try await transform
            let transformed = size.applying(preferredTransform)
            let width = abs(transformed.width)
            let height = abs(transformed.height)
            let dimensions = width > 0 && height > 0 ? CGSize(width: width, height: height) : nil
            let frameRateValue = try await nominalFrameRate
            let frameRate = frameRateValue > 0 ? Double(frameRateValue) : nil
            let formatDescriptions = try await descriptions
            let codec = formatDescriptions.first.map(codecLabel)

            return VideoScanInfo(
                duration: duration,
                dimensions: dimensions,
                codec: codec,
                frameRate: frameRate,
                isPlayable: try await loadedPlayable
            )
        } catch {
            return unavailable
        }
    }

    private static let unavailable = VideoScanInfo(
        duration: nil,
        dimensions: nil,
        codec: nil,
        frameRate: nil,
        isPlayable: false
    )

    private static func codecLabel(_ description: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        let fourCC = String(bytes: bytes, encoding: .macOSRoman)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fourCC, !fourCC.isEmpty else { return String(format: "0x%08X", code) }
        switch fourCC.lowercased() {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "apch": return "Apple ProRes 422 HQ"
        case "apcn": return "Apple ProRes 422"
        case "apcs": return "Apple ProRes 422 LT"
        case "apco": return "Apple ProRes 422 Proxy"
        case "ap4h": return "Apple ProRes 4444"
        default: return fourCC.uppercased()
        }
    }
}

enum MediaDurationFormat {
    static func display(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let rounded = Int(seconds.rounded())
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let remaining = rounded % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%d:%02d", minutes, remaining)
    }

    static func accessibility(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "Unknown duration" }
        let rounded = Int(seconds.rounded())
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let remaining = rounded % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if remaining > 0 || parts.isEmpty { parts.append("\(remaining) second\(remaining == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}
