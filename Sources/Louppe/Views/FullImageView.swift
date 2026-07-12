import SwiftUI
import AppKit

/// The big central image in the culling view, with fit / 100% / phone-size zoom.
struct FullImageView: View {
    let item: PhotoItem
    @Binding var zoomMode: ZoomMode

    @State private var image: NSImage?
    @State private var failedToLoad = false

    var body: some View {
        Group {
            if let image {
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
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task(id: item.id) {
            failedToLoad = false
            let loaded = await ImagePipeline.shared.fullImage(for: item.primaryURL)
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
