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

    func testFittedImageClickMapsThroughLetterboxing() {
        let frame = FittedImageGeometry.frame(
            imageSize: CGSize(width: 2000, height: 1000),
            containerSize: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(
            frame,
            CGRect(x: 0, y: 250, width: 1000, height: 500)
        )

        let position = FittedImageGeometry.normalizedPosition(
            at: CGPoint(x: 250, y: 375),
            in: frame
        )
        XCTAssertEqual(position?.x ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(position?.y ?? -1, 0.25, accuracy: 0.001)
        XCTAssertNil(
            FittedImageGeometry.normalizedPosition(
                at: CGPoint(x: 250, y: 100),
                in: frame
            )
        )
    }

    func testPhoneSizeFitRetainsAspectRatioAndContainerCenter() {
        let frame = FittedImageGeometry.frame(
            imageSize: CGSize(width: 3000, height: 2000),
            containerSize: CGSize(width: 1200, height: 900),
            maximumSize: CGSize(width: 400, height: 600)
        )

        XCTAssertEqual(frame.width, 400, accuracy: 0.001)
        XCTAssertEqual(frame.height, 266.667, accuracy: 0.001)
        XCTAssertEqual(frame.midX, 600, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 450, accuracy: 0.001)
    }

    func testFittedImageDoubleClickViewReportsTheClickedPoint() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let clickView = FittedImageDoubleClickView(
            frame: window.contentView!.bounds
        )
        window.contentView = clickView
        var reportedPosition: NormalizedImagePosition?
        clickView.onDoubleClick = { position in
            reportedPosition = position
        }

        clickView.mouseDown(
            with: try mouseDownEvent(
                in: clickView,
                at: CGPoint(x: 100, y: 50),
                clickCount: 1,
                eventNumber: 1
            )
        )
        XCTAssertNil(reportedPosition)

        clickView.mouseDown(
            with: try mouseDownEvent(
                in: clickView,
                at: CGPoint(x: 100, y: 50),
                clickCount: 2,
                eventNumber: 2
            )
        )
        XCTAssertEqual(reportedPosition?.x ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(reportedPosition?.y ?? -1, 0.25, accuracy: 0.001)

        reportedPosition = nil
        clickView.mouseDown(
            with: try mouseDownEvent(
                in: clickView,
                at: CGPoint(x: 401, y: 50),
                clickCount: 2,
                eventNumber: 3
            )
        )
        XCTAssertNil(reportedPosition)
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

    func testDoubleClickTogglesRequestedActualAndFitWhileSStillResets() {
        let store = readyStore()
        let clicked = NormalizedImagePosition(x: 0.21, y: 0.74)

        store.zoomToActual(at: clicked)

        XCTAssertEqual(store.zoomMode, .actual)
        XCTAssertEqual(store.actualSizeViewport.position, clicked)

        store.zoomToFit()

        XCTAssertEqual(store.zoomMode, .fit)
        XCTAssertEqual(store.actualSizeViewport.position, clicked)

        store.toggleZoom(.actual)

        XCTAssertEqual(store.zoomMode, .actual)
        XCTAssertEqual(store.actualSizeViewport.position, .center)
    }

    func testActualScrollViewDoubleClickOnlyExitsOverDisplayedImage() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let scrollView = ActualSizeScrollView(frame: window.contentView!.bounds)
        window.contentView = scrollView
        let preview = NSImage(size: CGSize(width: 100, height: 100))
        var exitCount = 0
        scrollView.configure(
            item: makeItem("PREVIEW.JPG"),
            preview: preview,
            showsClippingWarnings: false,
            viewport: ActualSizeViewport(),
            onDoubleClick: {
                exitCount += 1
            },
            onLoading: { _ in }
        )
        scrollView.layoutSubtreeIfNeeded()

        let inside = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: CGPoint(x: 160, y: 120),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 2,
                pressure: 1
            )
        )
        scrollView.documentView?.mouseDown(with: inside)
        XCTAssertEqual(exitCount, 1)

        let outside = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: CGPoint(x: 10, y: 120),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 2,
                pressure: 1
            )
        )
        scrollView.documentView?.mouseDown(with: outside)
        XCTAssertEqual(exitCount, 1)
        scrollView.prepareForRemoval()
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
            showsClippingWarnings: false,
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
            showsClippingWarnings: false,
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
            showsClippingWarnings: false,
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

    func testActualSizeClippingTileUsesTheSharedRedWarning() async throws {
        let pipeline = HighResolutionImagePipeline.shared
        pipeline.removeAllTiles()
        let source = ZoomImageSource(
            key: "clipping-\(UUID().uuidString)",
            image: CIImage(
                color: CIColor(red: 1, green: 1, blue: 1)
            ).cropped(
                to: CGRect(x: 0, y: 0, width: 8, height: 8)
            ),
            pixelSize: CGSize(width: 8, height: 8)
        )

        guard let tile = await pipeline.tile(
            for: source,
            coordinate: ZoomTileCoordinate(column: 0, row: 0),
            showsClippingWarnings: true
        ) else {
            throw XCTSkip(
                "Core Image rendering service is unavailable in this sandbox"
            )
        }

        let pixel = try firstRGBPixel(of: tile.image)
        XCTAssertGreaterThan(pixel.red, 240)
        XCTAssertLessThan(pixel.green, 100)
        XCTAssertLessThan(pixel.blue, 100)
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

    private func mouseDownEvent(
        in view: NSView,
        at localPoint: CGPoint,
        clickCount: Int,
        eventNumber: Int
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: view.convert(localPoint, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: eventNumber,
                clickCount: clickCount,
                pressure: 1
            )
        )
    }
}
