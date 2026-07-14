import SwiftUI

/// The contact-sheet grid: click to cycle a photo's rating, double-click to
/// open it in the culling view, click-and-drag to rubber-band-select several
/// photos at once. Days are separated by a horizontal line and each day
/// starts on a fresh row. ⌘+/⌘− resize the tiles.
struct LightTableView: View {
    @ObservedObject var store: SessionStore

    /// Coordinate space of the grid content — tile frames and the rubber
    /// band both live in it, so they stay aligned while scrolling.
    private static let gridSpace = "lightTableGrid"

    /// Frames of the currently rendered tiles, keyed by absolute item index.
    /// (Lazy grids only report tiles that exist on screen — the rubber band
    /// can only touch what's rendered, which is all the user can see anyway.)
    /// Held in a reference box, NOT @State: the frames are read only inside
    /// the drag gesture, so updating them as tiles scroll in and out must not
    /// invalidate the grid body (which would re-run dayGroups every frame).
    @State private var tileFrames = TileFrameStore()
    /// The selection rectangle while a drag is in progress.
    @State private var rubberBand: CGRect?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: store.gridThumbSize, maximum: store.gridThumbSize * 1.4), spacing: 10)]
    }

    /// Photos grouped into runs of consecutive same-day shots, in session
    /// order. Each group renders as its own grid, so a new day always starts
    /// on a fresh row. Each element keeps its global index for rating/jumping.
    private var dayGroups: [[(index: Int, item: PhotoItem)]] {
        var groups: [[(index: Int, item: PhotoItem)]] = []
        for (position, entry) in store.visibleItems.enumerated() {
            if position == 0 || store.startsNewDay(atVisiblePosition: position) {
                groups.append([])
            }
            groups[groups.count - 1].append(entry)
        }
        return groups
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.visibleIndices.isEmpty && store.filter.isActive {
                    ContentUnavailableView(
                        "No photos match the filter",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust or reset the filter in the toolbar to see photos again.")
                    )
                    .padding(.top, 80)
                }
                LazyVStack(spacing: 14) {
                    ForEach(Array(dayGroups.enumerated()), id: \.offset) { groupIndex, group in
                        if groupIndex > 0 {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.secondary.opacity(0.4))
                                .frame(height: 2)
                                .padding(.horizontal, 4)
                        }
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(group, id: \.item.id) { index, item in
                                cell(index: index, item: item)
                            }
                        }
                    }
                }
                .padding(12)
                // Make the gaps between tiles draggable too, so a rubber band
                // can start anywhere in the grid.
                .contentShape(Rectangle())
                .overlay(alignment: .topLeading) { rubberBandOverlay }
                .coordinateSpace(name: Self.gridSpace)
                .simultaneousGesture(rubberBandGesture)
                // Mutating the box (not reassigning @State) keeps this off the
                // view-invalidation path — scrolling stays cheap.
                .onPreferenceChange(TileFrameKey.self) { tileFrames.frames = $0 }
            }
            .background(Color.appBackground)
            .onAppear {
                if let item = store.currentItem {
                    proxy.scrollTo(item.id, anchor: .center)
                }
            }
            .onChange(of: store.currentIndex) {
                if let item = store.currentItem {
                    proxy.scrollTo(item.id, anchor: .center)
                }
            }
        }
    }

    private func cell(index: Int, item: PhotoItem) -> some View {
        VStack(spacing: 3) {
            ThumbnailView(
                item: item,
                isCurrent: index == store.currentIndex,
                isSelected: store.selectedIndices.contains(index)
            )
            .aspectRatio(1, contentMode: .fit)
            Text(item.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .id(item.id)
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TileFrameKey.self,
                    value: [index: geo.frame(in: .named(Self.gridSpace))]
                )
            }
        )
        .gesture(
            TapGesture(count: 2).onEnded {
                // Double-click: open in the main culling view.
                store.setIndex(index)
                store.viewMode = .culling
            }
            .exclusively(before: TapGesture(count: 1).onEnded {
                // ⇧-click: range · ⌘-click: add/remove · click: cycle rating
                // (a click on a multi-selected photo rates the whole selection).
                store.handleThumbnailClick(at: index) {
                    store.toggleRating(at: index)
                }
            })
        )
    }

    // MARK: - Rubber-band selection

    private var rubberBandGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                rubberBand = rect
                store.setSelection(Set(tileFrames.frames.filter { $0.value.intersects(rect) }.map(\.key)))
            }
            .onEnded { _ in
                rubberBand = nil
                store.commitSelectionAnchor()
            }
    }

    @ViewBuilder
    private var rubberBandOverlay: some View {
        if let rect = rubberBand {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.louppeAccent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.louppeAccent.opacity(0.8), lineWidth: 1)
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

/// Collects the on-screen tiles' frames (in the grid's coordinate space)
/// so the rubber band can hit-test them.
private struct TileFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A mutable box for the tile frames. Held in @State so it survives redraws,
/// but mutated (not reassigned) so writes don't invalidate the view — the
/// frames feed the drag gesture only, never the rendered output.
private final class TileFrameStore {
    var frames: [Int: CGRect] = [:]
}
