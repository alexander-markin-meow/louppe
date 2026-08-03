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

    func testControllerReplacesSameIDPhysicalVideoReplacement() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "louppe-video-replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("SAME.MOV")
        let fixedDate = Date(timeIntervalSince1970: 1_650_000_000)
        try Data("first".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: url.path
        )
        let first = makeVideoItem(at: url, modificationDate: fixedDate)
        let controller = VideoPlaybackController()
        controller.prepare(first)
        let firstPlayerItem = try XCTUnwrap(controller.player.currentItem)

        try Data("other".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: url.path
        )
        let replacement = makeVideoItem(
            at: url,
            modificationDate: fixedDate
        )
        XCTAssertEqual(first.id, replacement.id)
        XCTAssertNotEqual(first.contentRevision, replacement.contentRevision)

        controller.prepare(replacement)
        let replacementPlayerItem = try XCTUnwrap(
            controller.player.currentItem
        )
        XCTAssertFalse(firstPlayerItem === replacementPlayerItem)
        XCTAssertFalse(controller.represents(first))
        XCTAssertTrue(controller.represents(replacement))
        controller.stop()
    }

    func testDelayedFirstAFailureCannotPoisonReplacementA() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "louppe-video-aba-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let aURL = folder.appendingPathComponent("A.wav")
        let bURL = folder.appendingPathComponent("B.wav")
        try writeSilentWAV(to: aURL)
        try writeSilentWAV(to: bURL)
        let a = makeVideoItem(
            at: aURL,
            modificationDate: try XCTUnwrap(
                aURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            )
        )
        let b = makeVideoItem(
            at: bURL,
            modificationDate: try XCTUnwrap(
                bURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            )
        )
        let controller = VideoPlaybackController()
        controller.prepare(a)
        let firstAPlayerItem = try XCTUnwrap(controller.player.currentItem)

        // Posting on the main queue invokes the observer now, but its
        // main-actor Task cannot run until this test yields. Recreate the same
        // A revision before that happens to exercise the A → B → A hazard.
        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: firstAPlayerItem,
            userInfo: [
                AVPlayerItemFailedToPlayToEndTimeErrorKey:
                    NSError(
                        domain: "LouppeTests.StalePlayer",
                        code: 1
                    ),
            ]
        )
        controller.prepare(b)
        controller.prepare(a)
        XCTAssertNil(controller.errorMessage)

        await Task.yield()

        XCTAssertNil(
            controller.errorMessage,
            "a queued failure from the first A must not poison the new A item"
        )
        controller.stop()
    }

    func testStartingFileOperationStopsActivePlayback() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "louppe-video-operation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ACTIVE.wav")
        try writeSilentWAV(to: url)
        let item = makeVideoItem(
            at: url,
            modificationDate: try XCTUnwrap(
                url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            )
        )
        let store = SessionStore()
        store.items = [item]
        store.phase = .ready
        store.videoPlayback.prepare(item)
        XCTAssertNotNil(store.videoPlayback.player.currentItem)

        XCTAssertTrue(store.exportWillStart(mode: .copy))

        XCTAssertNil(store.videoPlayback.player.currentItem)
        XCTAssertNil(store.videoPlayback.itemID)
        store.finishExport(
            mode: .copy,
            movedIDs: [],
            requiresRecovery: false
        )
    }

    private func makeVideoItem(
        at url: URL,
        modificationDate: Date
    ) -> PhotoItem {
        PhotoItem(
            id: url.lastPathComponent,
            primaryURL: url,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: .video,
            videoIsPlayable: true,
            primaryModificationDate: modificationDate,
            fileSize: 5
        )
    }

    private func writeSilentWAV(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = 8_000
        let bytesPerSample: UInt16 = 2
        let dataByteCount = sampleCount * UInt32(bytesPerSample)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(36 + dataByteCount, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data) // PCM
        appendLittleEndian(UInt16(1), to: &data) // mono
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * UInt32(bytesPerSample), to: &data)
        appendLittleEndian(bytesPerSample, to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(dataByteCount, to: &data)
        data.append(Data(count: Int(dataByteCount)))
        try data.write(to: url, options: .atomic)
    }

    private func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
