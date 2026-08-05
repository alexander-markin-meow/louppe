import SwiftUI

extension PhotoColorLabel {
    var swatchColor: Color {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

/// Independent decision, star, and color controls shared by single-photo and
/// batch editing in the Info panel.
struct MetadataEditingControls: View {
    @ObservedObject var store: SessionStore
    var showsDecision = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsDecision {
                HStack {
                    Text("Decision")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    MetadataDecisionButton(store: store, size: 22)
                }
            }

            HStack(spacing: 3) {
                Text("Stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    store.setStarRating(nil)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!store.canRate)
                .accessibilityLabel("Clear stars")

                ForEach(StarRating.allCases, id: \.self) { rating in
                    Button {
                        store.setStarRating(rating)
                    } label: {
                        Image(systemName: starSymbol(for: rating))
                            .frame(width: 18, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(starColor(for: rating))
                    .disabled(!store.canRate)
                    .accessibilityLabel("Set \(rating.count) stars")
                }
            }

            HStack {
                Text("Color label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("None") { store.setColorLabel(nil) }
                    Divider()
                    ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                        Button(label.displayName) {
                            store.setColorLabel(label)
                        }
                    }
                } label: {
                    Text(colorLabelText)
                        .foregroundStyle(colorLabelTint)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .tint(colorLabelTint)
                .fixedSize()
                .disabled(!store.canRate)
                .accessibilityLabel("Color label")
                .accessibilityValue(colorLabelText)
            }
        }
    }

    private func starSymbol(for rating: StarRating) -> String {
        switch store.effectiveStarRatingState {
        case .stars(let selected) where selected.count >= rating.count:
            return "star.fill"
        default:
            return "star"
        }
    }

    private func starColor(for rating: StarRating) -> Color {
        switch store.effectiveStarRatingState {
        case .stars(let selected) where selected.count >= rating.count:
            return .louppeAccent
        case .mixed:
            return .secondary
        default:
            return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var colorLabelText: String {
        switch store.effectiveColorLabelState {
        case .none: return "None"
        case .label(let label): return label.displayName
        case .mixed: return "Mixed"
        }
    }

    private var colorLabelTint: Color {
        switch store.effectiveColorLabelState {
        case .none: return .secondary
        case .label(let label): return label.swatchColor
        case .mixed: return .louppeAccent
        }
    }
}

/// The one decision control used in both the filename row and batch editor.
struct MetadataDecisionButton: View {
    @ObservedObject var store: SessionStore
    let size: CGFloat

    var body: some View {
        Button {
            store.toggleRating(at: store.currentIndex)
        } label: {
            RatingBadge(
                rating: store.effectiveDecisionState.effectiveRating,
                isMixed: store.effectiveDecisionState == .mixed,
                size: size
            )
            .frame(width: size + 6, height: size + 6)
        }
        .buttonStyle(.plain)
        .disabled(!store.canRate)
        .accessibilityLabel("Change decision")
        .accessibilityValue(
            MediaTileAccessibility.decisionDescription(
                for: store.effectiveDecisionState
            )
        )
        .help("Change Yes/No decision")
    }
}

struct ColorLabelMark: View {
    let state: PhotoItemColorLabelState

    var body: some View {
        Group {
            switch state {
            case .none:
                Circle()
                    .stroke(Color.secondary, lineWidth: 1.5)
            case .label(let label):
                // A filled Shape keeps its explicit label color inside Menu
                // labels; SF Symbols inherit the app's purple menu tint.
                Circle()
                    .fill(label.swatchColor)
            case .mixed:
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(Color.louppeAccent)
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

/// Small noninteractive summary for Browser and Grid thumbnails.
struct MetadataBadgeStrip: View {
    let starRatingState: PhotoItemStarRatingState
    let colorLabelState: PhotoItemColorLabelState

    var body: some View {
        if starRatingState != .unrated || colorLabelState != .none {
            HStack(spacing: 4) {
                switch starRatingState {
                case .unrated:
                    EmptyView()
                case .stars(let rating):
                    HStack(spacing: 1) {
                        Image(systemName: "star.fill")
                        Text("\(rating.count)")
                    }
                case .mixed:
                    Text("★–")
                }
                if colorLabelState != .none {
                    ColorLabelMark(state: colorLabelState)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(0.68), in: Capsule())
            .shadow(radius: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
