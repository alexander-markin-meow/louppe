import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

@MainActor
final class ZoomTests: XCTestCase {
    func testActualSizeUsesBackingPixelsRatherThanPoints() {
        XCTAssertEqual(
            ActualSizeGeometry.documentSize(
                sourcePixels: CGSize(width: 6000, height: 4000),
                backingScale: 1
            ),
            CGSize(width: 6000, height: 4000)
        )
        XCTAssertEqual(
            ActualSizeGeometry.documentSize(
                sourcePixels: CGSize(width: 6000, height: 4000),
                backingScale: 2
            ),
            CGSize(width: 3000, height: 2000)
        )
    }

    func testNormalizedViewportPositionRoundTripsAcrossImageSizes() {
        let position = NormalizedImagePosition(x: 0.25, y: 0.75)
        let viewport = CGSize(width: 1000, height: 800)
        let firstDocument = CGSize(width: 3000, height: 2000)
        let firstOffset = ActualSizeGeometry.contentOffset(
            for: position,
            documentSize: firstDocument,
            viewportSize: viewport
        )
        XCTAssertEqual(firstOffset.x, 250, accuracy: 0.001)
        XCTAssertEqual(firstOffset.y, 1100, accuracy: 0.001)
        XCTAssertEqual(
            ActualSizeGeometry.normalizedPosition(
                contentOffset: firstOffset,
                documentSize: firstDocument,
                viewportSize: viewport,
                preserving: .center
            ),
            position
        )

        let portraitDocument = CGSize(width: 2000, height: 4000)
        let portraitOffset = ActualSizeGeometry.contentOffset(
            for: position,
            documentSize: portraitDocument,
            viewportSize: viewport
        )
        XCTAssertEqual(
            ActualSizeGeometry.normalizedPosition(
                contentOffset: portraitOffset,
                documentSize: portraitDocument,
                viewportSize: viewport,
                preserving: .center
            ),
            position
        )
    }

    func testUnscrollableAxisDoesNotErasePreferredPosition() {
        let previous = NormalizedImagePosition(x: 0.18, y: 0.82)
        let result = ActualSizeGeometry.normalizedPosition(
            contentOffset: CGPoint(x: 0, y: 900),
            documentSize: CGSize(width: 400, height: 2000),
            viewportSize: CGSize(width: 1000, height: 800),
            preserving: previous
        )

        XCTAssertEqual(result.x, previous.x)
        XCTAssertEqual(result.y, 0.65, accuracy: 0.001)
    }

    func testNavigationKeepsPositionAndSResetsIt() {
        _ = NSApplication.shared
        let store = readyStore()
        let view = SessionView(store: store)

        XCTAssertTrue(view.handleKey(keyEvent(code: 1, characters: "s")))
        XCTAssertEqual(store.zoomMode, .actual)
        XCTAssertEqual(store.actualSizeViewport.position, .center)

        let inspectionPoint = NormalizedImagePosition(x: 0.2, y: 0.7)
        store.actualSizeViewport.update(position: inspectionPoint)
        XCTAssertTrue(view.handleKey(keyEvent(code: 124)))
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.actualSizeViewport.position, inspectionPoint)

        XCTAssertTrue(view.handleKey(keyEvent(code: 1, characters: "s")))
        XCTAssertEqual(store.zoomMode, .fit)
        XCTAssertEqual(store.actualSizeViewport.position, .center)
    }

    func testActualScrollViewRestoresPositionForNextFileAndReset() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "louppe-zoom-scroll-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstURL = folder.appendingPathComponent("FIRST.JPG")
        let secondURL = folder.appendingPathComponent("SECOND.JPG")
        try writeJPEG(width: 1600, height: 1200, to: firstURL)
        try writeJPEG(width: 1200, height: 1800, to: secondURL)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let scrollView = ActualSizeScrollView(frame: window.contentView!.bounds)
        window.contentView = scrollView
        let viewport = ActualSizeViewport()
        let first = makeItem("FIRST.JPG", url: firstURL)
        let second = makeItem("SECOND.JPG", url: secondURL)

        scrollView.configure(
            item: first,
            preview: nil,
            viewport: viewport,
            onLoading: { _ in }
        )
        let firstDocument = try await waitForScrollableDocument(
            in: scrollView
        )
        let requested = NormalizedImagePosition(x: 0.72, y: 0.63)
        let firstOffset = ActualSizeGeometry.contentOffset(
            for: requested,
            documentSize: firstDocument,
            viewportSize: scrollView.contentSize
        )
        scrollView.contentView.scroll(to: firstOffset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let captured = viewport.position
        XCTAssertEqual(captured.x, requested.x, accuracy: 0.002)
        XCTAssertEqual(captured.y, requested.y, accuracy: 0.002)

        scrollView.setFrameSize(CGSize(width: 400, height: 300))
        scrollView.layoutSubtreeIfNeeded()
        let resizedOffset = ActualSizeGeometry.contentOffset(
            for: captured,
            documentSize: firstDocument,
            viewportSize: scrollView.contentSize
        )
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.x,
            resizedOffset.x,
            accuracy: 1
        )
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            resizedOffset.y,
            accuracy: 1
        )
        XCTAssertEqual(viewport.position, captured)

        scrollView.configure(
            item: second,
            preview: nil,
            viewport: viewport,
            onLoading: { _ in }
        )
        let secondDocument = try await waitForScrollableDocument(
            in: scrollView,
            differentFrom: firstDocument
        )
        let expected = ActualSizeGeometry.contentOffset(
            for: captured,
            documentSize: secondDocument,
            viewportSize: scrollView.contentSize
        )
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.x,
            expected.x,
            accuracy: 1
        )
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            expected.y,
            accuracy: 1
        )

        viewport.reset()
        scrollView.configure(
            item: second,
            preview: nil,
            viewport: viewport,
            onLoading: { _ in }
        )
        let centered = ActualSizeGeometry.contentOffset(
            for: .center,
            documentSize: secondDocument,
            viewportSize: scrollView.contentSize
        )
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.x,
            centered.x,
            accuracy: 1
        )
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            centered.y,
            accuracy: 1
        )
        scrollView.prepareForRemoval()
    }

    func testTopLeftTileMapsToTopOfOrientedSource() async throws {
        let pipeline = HighResolutionImagePipeline.shared
        pipeline.removeAllTiles()
        let sourceSize = CGSize(width: 1024, height: 2048)
        let blue = CIImage(
            color: CIColor(red: 0, green: 0, blue: 1)
        ).cropped(to: CGRect(origin: .zero, size: sourceSize))
        let redTop = CIImage(
            color: CIColor(red: 1, green: 0, blue: 0)
        ).cropped(to: CGRect(x: 0, y: 1024, width: 1024, height: 1024))
        let source = ZoomImageSource(
            key: "orientation-\(UUID().uuidString)",
            image: redTop.composited(over: blue),
            pixelSize: sourceSize
        )

        guard
            let top = await pipeline.tile(
                for: source,
                coordinate: ZoomTileCoordinate(column: 0, row: 0)
            ),
            let bottom = await pipeline.tile(
                for: source,
                coordinate: ZoomTileCoordinate(column: 0, row: 1)
            )
        else {
            throw XCTSkip(
                "Core Image rendering service is unavailable in this sandbox"
            )
        }

        let topPixel = try firstRGBPixel(of: top.image)
        let bottomPixel = try firstRGBPixel(of: bottom.image)
        XCTAssertGreaterThan(topPixel.red, topPixel.blue)
        XCTAssertGreaterThan(bottomPixel.blue, bottomPixel.red)
        pipeline.removeAllTiles()
    }

    func testFileSourceAppliesEXIFOrientationBeforeTiling() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "louppe-zoom-orientation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ROTATED.JPG")
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 30,
            pixelsHigh: 20,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let image = bitmap.cgImage,
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            XCTFail("Could not create orientation fixture")
            return
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyOrientation:
                    CGImagePropertyOrientation.right.rawValue
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let item = PhotoItem(
            id: "ROTATED.JPG",
            primaryURL: url,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let source = await HighResolutionImagePipeline.shared.source(
            for: item
        )

        XCTAssertEqual(source?.pixelSize, CGSize(width: 20, height: 30))
    }

    func testHundredMegapixelSourceKeepsDecodedTilesWithinBudget() async throws {
        let pipeline = HighResolutionImagePipeline.shared
        pipeline.removeAllTiles()
        let sourceSize = CGSize(width: 10_000, height: 10_000)
        let source = ZoomImageSource(
            key: "synthetic-100mp-\(UUID().uuidString)",
            image: CIImage(
                color: CIColor(red: 0.25, green: 0.5, blue: 0.75)
            ).cropped(to: CGRect(origin: .zero, size: sourceSize)),
            pixelSize: sourceSize
        )

        guard await pipeline.tile(
            for: source,
            coordinate: ZoomTileCoordinate(column: 0, row: 0)
        ) != nil else {
            throw XCTSkip(
                "Core Image rendering service is unavailable in this sandbox"
            )
        }

        for row in 0..<5 {
            for column in 0..<8 {
                let tile = await pipeline.tile(
                    for: source,
                    coordinate: ZoomTileCoordinate(
                        column: column,
                        row: row
                    )
                )
                XCTAssertNotNil(tile)
            }
        }

        XCTAssertLessThanOrEqual(
            pipeline.cachedTileCost,
            HighResolutionImagePipeline.tileCacheCostLimit
        )
        XCTAssertLessThan(pipeline.cachedTileCount, 40)

        let edge = await pipeline.tile(
            for: source,
            coordinate: ZoomTileCoordinate(column: 9, row: 9)
        )
        XCTAssertEqual(edge?.pixelRect, CGRect(x: 9216, y: 9216, width: 784, height: 784))
        XCTAssertEqual(edge?.image.width, 784)
        XCTAssertEqual(edge?.image.height, 784)
        pipeline.removeAllTiles()
    }

    private func firstRGBPixel(
        of image: CGImage
    ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= 3 else {
            XCTFail("Rendered tile should expose pixel data")
            throw NSError(domain: "ZoomTests", code: 1)
        }
        return (bytes[0], bytes[1], bytes[2])
    }

    private func readyStore() -> SessionStore {
        let store = SessionStore()
        store.items = [
            makeItem("A.JPG"),
            makeItem("B.JPG"),
            makeItem("C.JPG"),
        ]
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        return store
    }

    private func makeItem(_ id: String) -> PhotoItem {
        makeItem(id, url: URL(fileURLWithPath: "/tmp/\(id)"))
    }

    private func makeItem(_ id: String, url: URL) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: url,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
    }

    private func writeJPEG(
        width: Int,
        height: Int,
        to url: URL
    ) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.2]
        ) else {
            throw NSError(domain: "ZoomTests", code: 2)
        }
        try data.write(to: url, options: .atomic)
    }

    private func waitForScrollableDocument(
        in scrollView: ActualSizeScrollView,
        differentFrom previous: CGSize? = nil
    ) async throws -> CGSize {
        for _ in 0..<200 {
            scrollView.layoutSubtreeIfNeeded()
            let size = scrollView.documentView?.frame.size ?? .zero
            let isDifferent = previous.map { size != $0 } ?? true
            if isDifferent,
               size.width > scrollView.contentSize.width,
               size.height > scrollView.contentSize.height {
                return size
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Actual-size document did not finish loading")
        throw NSError(domain: "ZoomTests", code: 3)
    }

    private func keyEvent(
        code: UInt16,
        characters: String = ""
    ) -> NSEvent {
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
