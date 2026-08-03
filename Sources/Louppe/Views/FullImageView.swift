import SwiftUI
import AppKit

/// The big central image in the Gallery view, with fit / 100% / phone-size zoom.
struct FullImageView: View {
    private static let navigationDebounceNanoseconds: UInt64 = 40_000_000

    let item: PhotoItem
    @Binding var zoomMode: ZoomMode
    let showsClippingWarnings: Bool
    let actualSizeViewport: ActualSizeViewport
    /// Fit/phone-size double-click asks the store to enter 100% at this point.
    let onZoomToActual: (NormalizedImagePosition) -> Void
    /// A second double-click in 100% asks the store to return to Fit.
    let onZoomToFit: () -> Void
    /// Reports decode start/finish upward — the toolbar shows a small spinner
    /// there instead of flashing one in the middle of the photo area.
    var onLoading: (Bool) -> Void

    @State private var image: NSImage?
    @State private var clippingImage: NSImage?
    /// Low-res stand-in (the Browser thumbnail) shown while the real
    /// decode runs, so switching photos never flashes an empty pane.
    @State private var preview: NSImage?
    @State private var failedToLoad = false
    @State private var imageRevision: PhotoContentRevision
    @State private var clippingRevision: PhotoContentRevision

    private struct ClippingLoadID: Hashable {
        let contentRevision: PhotoContentRevision
        let isEnabled: Bool
    }

    init(
        item: PhotoItem,
        zoomMode: Binding<ZoomMode>,
        showsClippingWarnings: Bool = false,
        actualSizeViewport: ActualSizeViewport,
        onZoomToActual: @escaping (NormalizedImagePosition) -> Void,
        onZoomToFit: @escaping () -> Void,
        onLoading: @escaping (Bool) -> Void = { _ in }
    ) {
        self.item = item
        self._zoomMode = zoomMode
        self.showsClippingWarnings = showsClippingWarnings
        self.actualSizeViewport = actualSizeViewport
        self.onZoomToActual = onZoomToActual
        self.onZoomToFit = onZoomToFit
        self.onLoading = onLoading
        let revision = item.contentRevision
        self._imageRevision = State(initialValue: revision)
        self._clippingRevision = State(initialValue: revision)
        // Seed from the in-memory caches — synchronous dictionary lookups,
        // nothing is decoded here. Prefetched neighbours appear instantly at
        // full quality; anything else starts from its thumbnail.
        guard item.isSupported else { return }
        let cachedFull = ImagePipeline.shared.cachedFullImage(for: item)
        self._image = State(initialValue: cachedFull)
        self._clippingImage = State(
            initialValue: ClippingPreviewPipeline.shared.cachedImage(for: item)
        )
        if cachedFull == nil {
            self._preview = State(initialValue: ImagePipeline.shared.cachedThumbnail(for: item))
        }
    }

    var body: some View {
        let contentRevision = item.contentRevision
        let displayedImage = imageRevision == contentRevision
            ? image
            : ImagePipeline.shared.cachedFullImage(for: item)
        let displayedPreview = imageRevision == contentRevision
            ? preview
            : ImagePipeline.shared.cachedThumbnail(for: item)
        let displayedClippingImage = clippingRevision == contentRevision
            ? clippingImage
            : ClippingPreviewPipeline.shared.cachedImage(for: item)
        let presentationImage = showsClippingWarnings
            ? displayedClippingImage ?? displayedImage
            : displayedImage
        let presentationPreview = showsClippingWarnings
            ? displayedClippingImage ?? displayedPreview
            : displayedPreview
        Group {
            if !item.isSupported {
                ContentUnavailableView(
                    "File isn't supported",
                    systemImage: "doc.questionmark",
                    description: Text("Louppe can't preview \(item.fileTypeLabel) files yet. You can still rate it — \(item.displayName)")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch zoomMode {
                case .actual:
                    ActualSizeImageView(
                        item: item,
                        preview: presentationImage ?? presentationPreview,
                        showsClippingWarnings: showsClippingWarnings,
                        viewport: actualSizeViewport,
                        onDoubleClick: onZoomToFit,
                        onLoading: onLoading
                    )
                case .fit where presentationImage != nil:
                    if let presentationImage {
                        ZoomableFittedImage(
                            image: presentationImage,
                            onDoubleClick: onZoomToActual
                        )
                    }
                case .small where presentationImage != nil:
                    if let presentationImage {
                        ZoomableFittedImage(
                            image: presentationImage,
                            maximumSize: CGSize(width: 400, height: 600),
                            onDoubleClick: onZoomToActual
                        )
                    }
                case .fit, .small:
                    if imageRevision == contentRevision, failedToLoad {
                        ContentUnavailableView(
                            "Can't preview this photo",
                            systemImage: "exclamationmark.triangle",
                            description: Text("The file may be corrupt or unreadable. You can still rate it — \(item.displayName)")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let presentationPreview {
                        // Blurry-but-instant stand-in; the full decode replaces it.
                        ZoomableFittedImage(
                            image: presentationPreview,
                            maximumSize: zoomMode == .small
                                ? CGSize(width: 400, height: 600)
                                : nil,
                            onDoubleClick: onZoomToActual
                        )
                    } else {
                        // Loading with nothing cached yet: keep the photo area
                        // quiet; the toolbar spinner is the indication.
                        Color.clear
                    }
                }
            }
        }
        .task(id: contentRevision) {
            let requestedItem = item
            let requestedRevision = requestedItem.contentRevision
            let cachedFull = ImagePipeline.shared.cachedFullImage(
                for: requestedItem
            )
            image = cachedFull
            preview = cachedFull == nil
                ? ImagePipeline.shared.cachedThumbnail(for: requestedItem)
                : nil
            failedToLoad = false
            imageRevision = requestedRevision
            guard requestedItem.isSupported, cachedFull == nil else { return }

            // Key repeat can create and cancel several view tasks in a few
            // milliseconds. Let stale tasks disappear before they add work.
            try? await Task.sleep(
                nanoseconds: Self.navigationDebounceNanoseconds
            )
            guard !Task.isCancelled, imageRevision == requestedRevision
            else { return }
            onLoading(true)
            defer { onLoading(false) }
            async let full = ImagePipeline.shared.fullImage(
                for: requestedItem
            )
            if preview == nil,
               let thumb = await ImagePipeline.shared.thumbnail(
                   for: requestedItem
               ),
               !Task.isCancelled,
               imageRevision == requestedRevision,
               image == nil {
                preview = thumb
            }
            let loaded = await full
            guard !Task.isCancelled, imageRevision == requestedRevision
            else { return }
            image = loaded
            failedToLoad = (loaded == nil)
        }
        .task(
            id: ClippingLoadID(
                contentRevision: contentRevision,
                isEnabled: showsClippingWarnings
            )
        ) {
            let requestedItem = item
            let requestedRevision = requestedItem.contentRevision
            let cached = ClippingPreviewPipeline.shared.cachedImage(
                for: requestedItem
            )
            clippingImage = cached
            clippingRevision = requestedRevision
            guard showsClippingWarnings,
                  requestedItem.mediaKind == .photo,
                  requestedItem.isSupported,
                  cached == nil
            else { return }
            // Match the normal preview's key-repeat protection. Without this,
            // clipping inspection immediately requested a full decode for
            // every transient photo and defeated the debounce above.
            try? await Task.sleep(
                nanoseconds: Self.navigationDebounceNanoseconds
            )
            guard !Task.isCancelled,
                  clippingRevision == requestedRevision else { return }
            onLoading(true)
            defer { onLoading(false) }
            let loaded = await ClippingPreviewPipeline.shared.image(
                for: requestedItem
            )
            guard !Task.isCancelled,
                  clippingRevision == requestedRevision else { return }
            clippingImage = loaded
        }
    }
}

/// Displays exactly the fitted image rectangle so only the photo—not its
/// letterboxed surroundings—owns the location-aware double-click gesture.
private struct ZoomableFittedImage: View {
    let image: NSImage
    var maximumSize: CGSize? = nil
    let onDoubleClick: (NormalizedImagePosition) -> Void

    var body: some View {
        GeometryReader { geometry in
            let imageFrame = FittedImageGeometry.frame(
                imageSize: image.size,
                containerSize: geometry.size,
                maximumSize: maximumSize
            )
            if !imageFrame.isEmpty {
                Image(nsImage: image)
                    .resizable()
                    .frame(
                        width: imageFrame.width,
                        height: imageFrame.height
                    )
                    .position(
                        x: imageFrame.midX,
                        y: imageFrame.midY
                    )
                    .contentShape(Rectangle())
                    .overlay {
                        FittedImageDoubleClickOverlay(
                            onDoubleClick: onDoubleClick
                        )
                        .accessibilityHidden(true)
                    }
                    .accessibilityHint(
                        "Double-click to inspect this point at 100 percent."
                    )
            }
        }
    }
}

/// A native macOS click surface sized to the rendered photo rectangle. It
/// reports pointer locations in the same top-left coordinate system used by
/// the tiled 100% viewport.
private struct FittedImageDoubleClickOverlay: NSViewRepresentable {
    let onDoubleClick: (NormalizedImagePosition) -> Void

    func makeNSView(context: Context) -> FittedImageDoubleClickView {
        let view = FittedImageDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(
        _ nsView: FittedImageDoubleClickView,
        context: Context
    ) {
        nsView.onDoubleClick = onDoubleClick
    }
}

@MainActor
final class FittedImageDoubleClickView: NSView {
    override var isFlipped: Bool { true }

    var onDoubleClick: (NormalizedImagePosition) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let position = FittedImageGeometry.normalizedPosition(
            at: point,
            in: bounds
        ) else {
            return
        }
        onDoubleClick(position)
    }
}
