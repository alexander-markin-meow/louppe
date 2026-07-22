import AppKit
import AVFoundation
import CoreVideo
import Foundation
import UniformTypeIdentifiers

@main
struct VideoChecks {
    static func main() async throws {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--make-fixture" {
            let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeMovie(to: folder.appendingPathComponent("VIDEO.MOV"))
            try writePhoto(to: folder.appendingPathComponent("PHOTO.JPG"))
            print(folder.path)
            return
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeVideoChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let nativeMovieExtensions = AVURLAsset.audiovisualContentTypes
            .filter { $0.conforms(to: .movie) }
            .compactMap(\.preferredFilenameExtension)
        try expect(!nativeMovieExtensions.isEmpty, "macOS should advertise native movie types")
        try expect(
            nativeMovieExtensions.allSatisfy(FolderScanner.isVideoExtension),
            "scanner should recognise every movie extension AVFoundation advertises"
        )
        try expect(
            FolderScanner.videoExtensions.allSatisfy(FolderScanner.isVideoExtension),
            "scanner should retain every explicit common video fallback"
        )

        let movieURL = folder.appendingPathComponent("FIRST-FRAME.MOV")
        try writeMovie(to: movieURL)

        let scanInfo = VideoMetadataExtractor.scanInfo(for: movieURL)
        try expect(scanInfo.isPlayable, "generated ProRes MOV should be playable")
        try expect((scanInfo.duration ?? 0) >= 1, "generated movie should expose its duration")
        try expect(scanInfo.dimensions == CGSize(width: 96, height: 64), "movie dimensions should be scan-cached")

        let item = PhotoItem(
            id: movieURL.lastPathComponent,
            primaryURL: movieURL,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: .video,
            duration: scanInfo.duration,
            videoDimensions: scanInfo.dimensions,
            videoCodec: scanInfo.codec,
            videoFrameRate: scanInfo.frameRate,
            videoIsPlayable: scanInfo.isPlayable,
            primaryModificationDate: try movieURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            fileSize: Int64(try movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        )
        guard let thumbnail = await ImagePipeline.shared.thumbnail(for: item) else {
            throw CheckFailure("first movie frame did not produce a thumbnail")
        }
        try expect(isMostlyRed(thumbnail), "thumbnail should use the first red frame, not a later frame")

        let scanned = try FolderScanner.scan(folder) { _ in }
        guard let scannedMovie = scanned.first(where: {
            $0.primaryURL.standardizedFileURL.resolvingSymlinksInPath()
                == movieURL.standardizedFileURL.resolvingSymlinksInPath()
        }) else {
            throw CheckFailure("folder scan dropped the playable movie")
        }
        try expect(scannedMovie.isVideo && scannedMovie.videoIsPlayable, "folder scan should classify the native movie as playable video")
        try expect(scannedMovie.duration != nil, "folder scan should retain video duration")

        try await MainActor.run {
            let playback = VideoPlaybackController()
            playback.prepare(item)
            try expect(playback.isActive(item), "session player should prepare the selected video")
            playback.toggle(item)
            try expect(playback.isPlaying, "Grid play action should start the shared player")
            playback.pause()
            try expect(!playback.isPlaying && playback.isActive(item), "pause should preserve the active video and position")
            playback.stop()
            try expect(!playback.isActive(item), "stop should detach the player item")
        }

        let brokenURL = folder.appendingPathComponent("BROKEN.MKV")
        try Data("not a movie".utf8).write(to: brokenURL)
        let withBroken = try FolderScanner.scan(folder) { _ in }
        guard let broken = withBroken.first(where: {
            $0.primaryURL.standardizedFileURL.resolvingSymlinksInPath()
                == brokenURL.standardizedFileURL.resolvingSymlinksInPath()
        }) else {
            throw CheckFailure("recognized unsupported movie should remain visible")
        }
        try expect(broken.isVideo && !broken.videoIsPlayable, "damaged movie should be visible but unplayable")
        try expect(MediaDurationFormat.display(broken.duration) == "--:--", "unreadable movie should keep a visible duration placeholder")

        print("Video checks passed (18/18)")
    }

    private static func writeMovie(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: 96,
                AVVideoHeightKey: 64,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 96,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        guard writer.canAdd(input) else { throw CheckFailure("ProRes writer input was rejected") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CheckFailure("movie writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        let frames: [(CMTime, UInt32)] = [
            (.zero, 0xFFFF0000),      // BGRA red
            (CMTime(seconds: 1, preferredTimescale: 600), 0xFF00FF00),
        ]
        for (time, color) in frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let buffer = makePixelBuffer(color: color), adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? CheckFailure("movie frame append failed")
            }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 15) == .success,
              writer.status == .completed else {
            throw writer.error ?? CheckFailure("movie writer did not finish")
        }
    }

    private static func makePixelBuffer(color: UInt32) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            96,
            64,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let wordsPerRow = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt32>.size
        let pointer = base.bindMemory(to: UInt32.self, capacity: wordsPerRow * 64)
        for row in 0..<64 {
            pointer.advanced(by: row * wordsPerRow).initialize(repeating: color, count: 96)
        }
        return buffer
    }

    private static func writePhoto(to url: URL) throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 96,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else { throw CheckFailure("photo fixture allocation failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 96, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw CheckFailure("photo fixture encoding failed")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func isMostlyRed(_ image: NSImage) -> Bool {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
            return false
        }
        return color.redComponent > 0.65 && color.greenComponent < 0.35 && color.blueComponent < 0.35
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message) }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
