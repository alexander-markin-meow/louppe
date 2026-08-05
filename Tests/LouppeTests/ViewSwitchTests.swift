import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class ViewSwitchTests: XCTestCase {
    func testRepeatedGalleryGridSwitchesRenderTailMediaAndStayInteractive() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "louppe-view-switch-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = repositoryRoot.appendingPathComponent(
            "AppIcon/AppIcon.iconset/icon_128x128.png"
        )
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var items: [PhotoItem] = []
        items.reserveCapacity(106)
        for index in 0..<106 {
            let name = String(format: "ITEM_%03d.PNG", index)
            let url = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixture, to: url)
            let values = try url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            items.append(PhotoItem(
                id: name,
                primaryURL: url,
                pairedURL: nil,
                captureDate: baseDate.addingTimeInterval(
                    Double(index / 12) * 24 * 60 * 60
                ),
                cameraModel: nil,
                lensModel: nil,
                primaryModificationDate: values.contentModificationDate,
                fileSize: Int64(values.fileSize ?? 0)
            ))
        }

        let store = SessionStore()
        store.items = items
        // Force the normal derived-index path, then exercise several real day
        // sections rather than one synthetic, ungrouped list.
        store.sort = PhotoSort(key: .name, ascending: true)
        store.sort = PhotoSort(key: .captureDate, ascending: true)
        store.phase = .ready

        let hostingView = NSHostingView(
            rootView: SessionView(store: store)
                .frame(width: 1_100, height: 720)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_100, height: 720)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await waitForRenderedMode(
            .gallery,
            in: hostingView
        )

        // Change the current photo and the mode in one turn. Gallery's decode
        // debounce should cancel, while Grid must resolve and render the distant
        // lazy target before its thumbnail can enter the memory cache.
        let tail = try XCTUnwrap(items.last)
        store.currentIndex = items.count - 1
        let clock = ContinuousClock()
        let renderStart = clock.now
        store.viewMode = .grid
        try await waitForRenderedMode(.grid, in: hostingView)
        let renderElapsed = renderStart.duration(to: clock.now)
        XCTAssertLessThan(
            renderElapsed,
            .seconds(1),
            "the default Browser and Info panel must not block the first Grid frame"
        )

        // Media completion is deliberately measured separately: a slow RAW
        // decode may leave a placeholder briefly, but it must never delay the
        // Grid itself or prevent the main actor from rendering it.
        let thumbnailStart = clock.now
        try await waitForThumbnail(tail, in: hostingView)
        let thumbnailElapsed = thumbnailStart.duration(to: clock.now)
        XCTAssertLessThan(
            thumbnailElapsed,
            .seconds(2),
            "the tiny real-media fixture should still finish its thumbnail promptly"
        )
        hostingView.layoutSubtreeIfNeeded()
        let allClickSurfaceSizes = descendants(of: hostingView)
            .compactMap { ($0 as? GridImmediateClickSurface.ClickView)?.frame.size }
        let photoClickSurfaces = allClickSurfaceSizes.filter {
            $0.height >= store.gridThumbSize - 1
        }
        XCTAssertTrue(
            photoClickSurfaces.contains {
                $0.width >= store.gridThumbSize - 1
            },
            "Grid media surfaces must fill the adaptive column instead of shrinking to the thumbnail image's intrinsic size; rendered sizes: \(allClickSurfaceSizes)"
        )


#if DEBUG
        try await waitForMetadataRead(of: tail)
        let metadataCallCount = MetadataExtractorTestProbe.shared.callCount(
            for: tail.contentRevision
        )
#endif
        let sharedMetadataMarker = try XCTUnwrap(
            renderMarker(.metadata, in: hostingView)
        )

        store.viewMode = .gallery
        try await waitForRenderedMode(.gallery, in: hostingView)
        XCTAssertTrue(
            renderMarker(.metadata, in: hostingView)
                === sharedMetadataMarker
        )
        let warmStart = clock.now
        for _ in 0..<5 {
            store.viewMode = .grid
            try await waitForRenderedMode(.grid, in: hostingView)
            XCTAssertTrue(
                renderMarker(.metadata, in: hostingView)
                    === sharedMetadataMarker
            )
            store.viewMode = .gallery
            try await waitForRenderedMode(.gallery, in: hostingView)
            XCTAssertTrue(
                renderMarker(.metadata, in: hostingView)
                    === sharedMetadataMarker
            )
        }
        let warmElapsed = warmStart.duration(to: clock.now)

        XCTAssertLessThan(
            warmElapsed,
            .seconds(1),
            "warm view switches should never wait on media I/O or rebuild every control geometry"
        )
        XCTAssertEqual(store.viewMode, .gallery)

#if DEBUG
        // If either mode owned a separate MetadataPanel, the final Gallery
        // task would survive its 80 ms debounce and perform another file read.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            MetadataExtractorTestProbe.shared.callCount(
                for: tail.contentRevision
            ),
            metadataCallCount,
            "Gallery/Grid switches must keep one metadata task alive"
        )
#endif

        // Let best-effort thumbnail writes finish before deleting the fixture
        // files and their unique disk-cache entries.
        await ImagePipeline.shared.waitForPendingDiskWrites()
        removeDiskCacheEntries(for: items)
    }

    private func waitForRenderedMode(
        _ mode: ViewMode,
        in hostingView: NSView
    ) async throws {
        let expected: SessionRenderMarker.Kind
        let unexpected: SessionRenderMarker.Kind
        switch mode {
        case .gallery:
            expected = .gallery
            unexpected = .grid
        case .grid:
            expected = .grid
            unexpected = .gallery
        }
        for _ in 0..<200 {
            hostingView.layoutSubtreeIfNeeded()
            if renderMarker(expected, in: hostingView) != nil,
               renderMarker(unexpected, in: hostingView) == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(mode) did not finish rendering")
        throw NSError(domain: "ViewSwitchTests", code: 1)
    }

    private func waitForThumbnail(
        _ item: PhotoItem,
        in hostingView: NSView
    ) async throws {
        for _ in 0..<400 {
            hostingView.layoutSubtreeIfNeeded()
            if ImagePipeline.shared.cachedThumbnail(for: item) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the distant current Grid tile never requested its thumbnail")
        throw NSError(domain: "ViewSwitchTests", code: 2)
    }

    private func renderMarker(
        _ kind: SessionRenderMarker.Kind,
        in view: NSView
    ) -> SessionRenderMarker.MarkerView? {
        if let marker = view as? SessionRenderMarker.MarkerView,
           marker.kind == kind {
            return marker
        }
        for subview in view.subviews {
            if let marker = renderMarker(kind, in: subview) {
                return marker
            }
        }
        return nil
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

#if DEBUG
    private func waitForMetadataRead(of item: PhotoItem) async throws {
        for _ in 0..<200 {
            if MetadataExtractorTestProbe.shared.callCount(
                for: item.contentRevision
            ) > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the shared Info panel never read the current item's metadata")
        throw NSError(domain: "ViewSwitchTests", code: 3)
    }
#endif

    private func removeDiskCacheEntries(for items: [PhotoItem]) {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        let root = caches.appendingPathComponent(
            "Louppe/Thumbnails",
            isDirectory: true
        )
        for item in items {
            let url = root.appendingPathComponent(
                ImagePipeline.diskFileName(
                    for: ImagePipeline.cacheKey(for: item)
                )
            )
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
