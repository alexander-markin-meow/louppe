import SwiftUI
import AppKit

private let thumbnailCornerRadius: CGFloat = 6

/// Async-loading thumbnail tile with a yes/no/undecided badge overlay.
/// The whole photo fits inside the tile (letterboxed, never cropped).
struct ThumbnailView: View {
    let item: PhotoItem
    var isCurrent: Bool
    /// Part of a multi-selection: same accent as the current photo, dimmed.
    var isSelected: Bool = false

    @State private var image: NSImage?

    init(item: PhotoItem, isCurrent: Bool, isSelected: Bool = false) {
        self.item = item
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        // Reappearing lazy cells should render their memory-cached image on
        // their first frame instead of flashing a placeholder and scheduling
        // an otherwise unnecessary state update.
        self._image = State(
            initialValue: item.isSupported
                ? ImagePipeline.shared.cachedThumbnail(for: item)
                : nil
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if !item.isSupported {
                    UnsupportedThumbnail(item: item)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(
                            RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                    .strokeBorder(borderColor, lineWidth: 3)
            }

            RatingBadge(rating: item.rating)
                .padding(4)
        }
        .task(id: item.id) {
            guard item.isSupported, image == nil else { return }
            image = await ImagePipeline.shared.thumbnail(for: item)
        }
    }

    private var borderColor: Color {
        if isCurrent { return .louppeAccent }
        if isSelected { return .louppeAccent.opacity(0.45) }
        return .clear
    }
}

/// Grey placeholder tile shown for recognised-but-unpreviewable files
/// (other RAW formats, PNG/HEIC/WebP, video, …).
struct UnsupportedThumbnail: View {
    let item: PhotoItem

    var body: some View {
        RoundedRectangle(cornerRadius: thumbnailCornerRadius)
            .fill(Color(nsColor: .quaternaryLabelColor))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("File isn't supported")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item.fileTypeLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding(6)
            }
    }
}

/// The ✓ / ✗ / undecided dot shown on thumbnails and in the info panel.
struct RatingBadge: View {
    let rating: Rating
    var size: CGFloat = 14

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
        .font(.system(size: size, weight: .bold))
        .shadow(radius: 1.5)
    }
}
