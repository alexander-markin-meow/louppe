import SwiftUI
import AppKit

/// The big central image in the Gallery view, with fit / 100% / phone-size zoom.
struct FullImageView: View {
    let item: PhotoItem
    @Binding var zoomMode: ZoomMode
    let actualSizeViewport: ActualSizeViewport
    /// Reports decode start/finish upward — the toolbar shows a small spinner
    /// there instead of flashing one in the middle of the photo area.
    var onLoading: (Bool) -> Void

    @State private var image: NSImage?
    /// Low-res stand-in (the Browser thumbnail) shown while the real
    /// decode runs, so switching photos never flashes an empty pane.
    @State private var preview: NSImage?
    @State private var failedToLoad = false
    @State private var loadedItemID: String

    init(
        item: PhotoItem,
        zoomMode: Binding<ZoomMode>,
        actualSizeViewport: ActualSizeViewport,
        onLoading: @escaping (Bool) -> Void = { _ in }
    ) {
        self.item = item
        self._zoomMode = zoomMode
        self.actualSizeViewport = actualSizeViewport
        self.onLoading = onLoading
        self._loadedItemID = State(initialValue: item.id)
        // Seed from the in-memory caches — synchronous dictionary lookups,
        // nothing is decoded here. Prefetched neighbours appear instantly at
        // full quality; anything else starts from its thumbnail.
        guard item.isSupported else { return }
        let cachedFull = ImagePipeline.shared.cachedFullImage(for: item)
        self._image = State(initialValue: cachedFull)
        if cachedFull == nil {
            self._preview = State(initialValue: ImagePipeline.shared.cachedThumbnail(for: item))
        }
    }

    var body: some View {
        let displayedImage = loadedItemID == item.id
            ? image
            : ImagePipeline.shared.cachedFullImage(for: item)
        let displayedPreview = loadedItemID == item.id
            ? preview
            : ImagePipeline.shared.cachedThumbnail(for: item)
        Group {
            if !item.isSupported {
                ContentUnavailableView(
                    "File isn't supported",
                    systemImage: "doc.questionmark",
                    description: Text("Louppe can't preview \(item.fileTypeLabel) files yet. You can still rate it — \(item.displayName)")
                )
            } else {
                switch zoomMode {
                case .actual:
                    ActualSizeImageView(
                        item: item,
                        preview: displayedImage ?? displayedPreview,
                        viewport: actualSizeViewport,
                        onLoading: onLoading
                    )
                case .fit where displayedImage != nil:
                    if let displayedImage {
                        Image(nsImage: displayedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .small where displayedImage != nil:
                    if let displayedImage {
                        Image(nsImage: displayedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 400, maxHeight: 600)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .fit, .small:
                    if loadedItemID == item.id, failedToLoad {
                        ContentUnavailableView(
                            "Can't preview this photo",
                            systemImage: "exclamationmark.triangle",
                            description: Text("The file may be corrupt or unreadable. You can still rate it — \(item.displayName)")
                        )
                    } else if let displayedPreview {
                        // Blurry-but-instant stand-in; the full decode replaces it.
                        Image(nsImage: displayedPreview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Loading with nothing cached yet: keep the photo area
                        // quiet; the toolbar spinner is the indication.
                        Color.clear
                    }
                }
            }
        }
        .task(id: item.id) {
            let requestedItem = item
            let cachedFull = ImagePipeline.shared.cachedFullImage(
                for: requestedItem
            )
            image = cachedFull
            preview = cachedFull == nil
                ? ImagePipeline.shared.cachedThumbnail(for: requestedItem)
                : nil
            failedToLoad = false
            loadedItemID = requestedItem.id
            guard requestedItem.isSupported, cachedFull == nil else { return }

            // Key repeat can create and cancel several view tasks in a few
            // milliseconds. Let stale tasks disappear before they add work.
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, loadedItemID == requestedItem.id
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
               loadedItemID == requestedItem.id,
               image == nil {
                preview = thumb
            }
            let loaded = await full
            guard !Task.isCancelled, loadedItemID == requestedItem.id
            else { return }
            image = loaded
            failedToLoad = (loaded == nil)
        }
    }
}
