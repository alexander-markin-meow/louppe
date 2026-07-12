import SwiftUI
import AppKit

/// Async-loading thumbnail tile with a yes/no/undecided badge overlay.
/// The whole photo fits inside the tile (letterboxed, never cropped).
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
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
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

/// The ✓ / ✗ / undecided dot shown on thumbnails and in the info panel.
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
