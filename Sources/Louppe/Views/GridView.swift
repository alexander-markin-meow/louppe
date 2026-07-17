import SwiftUI

/// The Grid view: click to cycle a photo's rating, double-click to open it in
/// the Gallery view, and click-and-drag to rubber-band-select several
/// photos at once. Days are separated by a horizontal line and each day
/// starts on a fresh row. ⌘+/⌘− resize the tiles; W toggles photo info.
struct GridView: View {
    @ObservedObject var store: SessionStore

    /// The native scrollbar thumb is inset within its reserved gutter. A
    /// slightly smaller trailing content inset makes the visible photo-to-thumb
    /// gap match the 12-point window-edge-to-photo gap on the leading side.
    private static let leadingPadding: CGFloat = 12
    private static let trailingPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 12

    /// Coordinate space of the grid content — tile frames and the rubber
    /// band both live in it, so they stay aligned while scrolling.
    private static let gridSpace = "gridView"

    /// Frames of the currently rendered tiles, keyed by absolute item index.
    /// (Lazy grids only report tiles that exist on screen — the rubber band
    /// can only touch what's rendered, which is all the user can see anyway.)
    /// Held in a reference box, NOT @State: the frames are read only inside
    /// the drag gesture, so updating them as tiles scroll in and out must not
    /// invalidate the grid body (which would re-run dayGroups every frame).
    @State private var tileFrames = TileFrameStore()
    /// The selection rectangle while a drag is in progress.
    @State private var rubberBand: CGRect?
    /// A cancellable, one-shot follow request. Unlike a bound scroll position,
    /// this stays completely idle while the user manually scrolls the grid.
    @State private var followTask: Task<Void, Never>?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: store.gridThumbSize, maximum: store.gridThumbSize * 1.4), spacing: 10)]
    }

    var body: some View {
        HStack(spacing: 0) {
            grid
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.showMetadataPanel, let item = store.currentItem {
                Divider()
                MetadataPanel(store: store, item: item)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
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
                    // One lazy grid gives SwiftUI one stable row-height model.
                    // Nesting a separate LazyVGrid for every day inside a
                    // LazyVStack made off-screen day heights estimates; those
                    // estimates were corrected while scrolling upward or
                    // after a thumbnail resize, visibly moving the viewport.
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(store.visibleGroups.enumerated()), id: \.offset) { _, group in
                            Section {
                                ForEach(group.indices, id: \.self) { index in
                                    if store.items.indices.contains(index) {
                                        cell(index: index, item: store.items[index])
                                    }
                                }
                            } header: {
                                if let title = group.title {
                                    HStack(spacing: 8) {
                                        Text(title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(.secondary.opacity(0.4))
                                            .frame(height: 2)
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .padding(.vertical, Self.verticalPadding)
                    .padding(.leading, Self.leadingPadding)
                    .padding(.trailing, Self.trailingPadding)
                    .background(PersistentVerticalScroller())
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
                    updateColumnCount(for: geometry.size.width)
                    followCurrentPhoto(using: proxy, animated: false)
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    updateColumnCount(for: newWidth)
                }
                .onChange(of: store.gridThumbSize) { _, _ in
                    updateColumnCount(for: geometry.size.width)
                }
                .onChange(of: store.currentIndex) {
                    followCurrentPhoto(using: proxy, animated: true)
                }
                .onDisappear {
                    followTask?.cancel()
                }
            }
        }
    }

    private func followCurrentPhoto(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = store.currentItem?.id else { return }
        followTask?.cancel()
        followTask = Task { @MainActor in
            // Wait for the lazy day grid to receive the new current index,
            // then issue a second pass so very distant targets are resolved.
            await Task.yield()
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
            await Task.yield()
            guard !Task.isCancelled, store.currentItem?.id == id else { return }
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func updateColumnCount(for width: CGFloat) {
        // The legacy vertical scroller owns a real gutter inside the Grid's
        // width. Exclude it so arrow-key columns match the rendered grid.
        let contentWidth = max(
            width
                - Self.leadingPadding
                - Self.trailingPadding
                - PersistentVerticalScroller.gutterWidth,
            1
        )
        let spacing: CGFloat = 10
        let count = max(1, Int((contentWidth + spacing) / (store.gridThumbSize + spacing)))
        store.setGridColumnCount(count)
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
                // Double-click: open in the Gallery view.
                store.setIndex(index)
                store.viewMode = .gallery
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
