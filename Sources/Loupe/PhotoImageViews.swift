import SwiftUI
import AppKit

extension Color {
    /// The single background gray used everywhere in the app (filmstrip, photo
    /// pane, info panel, light table) so there's one consistent shade.
    static let appBackground = Color(nsColor: .windowBackgroundColor)
}

/// Async-loading thumbnail with a yes/no/undecided badge overlay.
struct ThumbnailView: View {
    let item: PhotoItem
    var isCurrent: Bool

    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 3)
            }

            RatingBadge(rating: item.rating)
                .padding(4)
        }
        .task(id: item.id) {
            image = await ImagePipeline.shared.thumbnail(for: item.primaryURL)
        }
    }
}

struct RatingBadge: View {
    let rating: Rating

    var body: some View {
        Group {
            switch rating {
            case .yes:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, .green)
            case .no:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .red)
            case .undecided:
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .opacity(0.85)
            }
        }
        .font(.system(size: 14, weight: .bold))
        .shadow(radius: 1.5)
    }
}

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
