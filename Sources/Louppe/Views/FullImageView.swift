import SwiftUI
import AppKit

/// The big central image in the culling view, with fit / 100% / phone-size zoom.
struct FullImageView: View {
    let item: PhotoItem
    @Binding var zoomMode: ZoomMode
    /// Reports decode start/finish upward — the toolbar shows a small spinner
    /// there instead of flashing one in the middle of the photo area.
    var onLoading: (Bool) -> Void

    @State private var image: NSImage?
    /// Low-res stand-in (the filmstrip's thumbnail) shown while the real
    /// decode runs, so switching photos never flashes an empty pane.
    @State private var preview: NSImage?
    @State private var failedToLoad = false

    init(item: PhotoItem, zoomMode: Binding<ZoomMode>, onLoading: @escaping (Bool) -> Void = { _ in }) {
        self.item = item
        self._zoomMode = zoomMode
        self.onLoading = onLoading
        // Seed from the in-memory caches — synchronous dictionary lookups,
        // nothing is decoded here. Prefetched neighbours appear instantly at
        // full quality; anything else starts from its thumbnail.
        guard item.isSupported else { return }
        let cachedFull = ImagePipeline.shared.cachedFullImage(for: item.primaryURL)
        self._image = State(initialValue: cachedFull)
        if cachedFull == nil {
            self._preview = State(initialValue: ImagePipeline.shared.cachedThumbnail(for: item.primaryURL))
        }
    }

    var body: some View {
        Group {
            if !item.isSupported {
                ContentUnavailableView(
                    "File isn't supported",
                    systemImage: "doc.questionmark",
                    description: Text("Louppe can't preview \(item.fileTypeLabel) files yet. You can still rate it — \(item.displayName)")
                )
            } else if let image {
                switch zoomMode {
                case .actual:
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: pixelSize(of: image).width, height: pixelSize(of: image).height)
                    }
                    .defaultScrollAnchor(.center)
                case .fit:
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .small:
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 400, maxHeight: 600)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if failedToLoad {
                ContentUnavailableView(
                    "Can't preview this photo",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The file may be corrupt or unreadable. You can still rate it — \(item.displayName)")
                )
            } else if let preview {
                // Blurry-but-instant stand-in; the full decode replaces it.
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Loading with nothing cached yet: keep the photo area quiet —
                // the toolbar spinner (via onLoading) is the only indication.
                Color.clear
            }
        }
        .task(id: item.id) {
            guard item.isSupported, image == nil else { return }
            failedToLoad = false
            onLoading(true)
            defer { onLoading(false) }
            // Full decode in the background; meanwhile grab the thumbnail as a
            // quick preview if the memory cache didn't have it at init (its
            // disk-cache load or 320px decode finishes far sooner).
            async let full = ImagePipeline.shared.fullImage(for: item.primaryURL)
            if preview == nil, let thumb = await ImagePipeline.shared.thumbnail(for: item.primaryURL) {
                if image == nil { preview = thumb }
            }
            let loaded = await full
            // The photo may have changed while decoding; .task(id:) cancels stale runs,
            // but guard against clearing a fresh image with a stale nil.
            if !Task.isCancelled {
                image = loaded
                failedToLoad = (loaded == nil)
            }
        }
    }

    private func pixelSize(of image: NSImage) -> CGSize {
        if let rep = image.representations.first {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }
}
