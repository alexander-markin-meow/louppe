import AppKit
import SwiftUI

/// The Grid view: click a photo to make it current, use its rating control to
/// cycle the decision, double-click to open it in the Gallery view, and
/// click-and-drag to rubber-band-select several photos at once. Days are
/// separated by a horizontal line and each day starts on a fresh row.
/// ⌘+/⌘− resize the tiles; W toggles photo info.
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
    /// A pointer click already targets a rendered tile, so centering that same
    /// tile would move the Grid under the pointer. Keyboard navigation and
    /// structural current-item changes continue to follow normally.
    @State private var suppressNextFollow = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: store.gridThumbSize, maximum: store.gridThumbSize * 1.4), spacing: 10)]
    }

    var body: some View {
        grid
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SessionRenderMarker(kind: .grid))
    }

    private var grid: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    if store.items.isEmpty {
                        SessionEmptyView(
                            reason: store.emptySessionReason,
                            canUndo: store.canUndo
                        )
                        .padding(.top, 80)
                    } else if store.visibleIndices.isEmpty
                                && store.filter.isActive {
                        ContentUnavailableView(
                            "No items match the filter",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Adjust or reset the filter in the toolbar to see media again.")
                        )
                        .padding(.top, 80)
                    }
                    // One lazy grid gives SwiftUI one stable row-height model.
                    // Nesting a separate LazyVGrid for every day inside a
                    // LazyVStack made off-screen day heights estimates; those
                    // estimates were corrected while scrolling upward or
                    // after a thumbnail resize, visibly moving the viewport.
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(store.visibleGroups) { group in
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
                // Follow the stable media identity as well as numeric index
                // changes: Clean Up or Move can replace an item at the same
                // index.
                .onChange(of: store.currentItem?.id) {
                    if suppressNextFollow {
                        suppressNextFollow = false
                        return
                    }
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
        GridCell(
            store: store,
            index: index,
            onPointerCurrentChange: suppressFollowForPointerAction
        )
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
    }

    private func suppressFollowForPointerAction() {
        suppressNextFollow = true
        followTask?.cancel()
    }

    // MARK: - Rubber-band selection

    private var rubberBandGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                guard rubberBandShouldTrackCanvas(
                    startingAt: value.startLocation
                ) else {
                    rubberBand = nil
                    return
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                rubberBand = rect
                store.setSelection(Set(tileFrames.frames.filter { $0.value.intersects(rect) }.map(\.key)))
            }
            .onEnded { value in
                defer { rubberBand = nil }
                guard rubberBandShouldTrackCanvas(
                    startingAt: value.startLocation
                ) else { return }
                store.commitSelectionAnchor()
            }
    }

    private func rubberBandShouldTrackCanvas(
        startingAt point: CGPoint
    ) -> Bool {
        let playableVideoIndices = Set(
            tileFrames.frames.keys.filter { index in
                store.items.indices.contains(index)
                    && store.items[index].isVideo
                    && store.items[index].videoIsPlayable
            }
        )
        return GridRubberBandHitTest.shouldTrackCanvasDrag(
            startingAt: point,
            tileFrames: tileFrames.frames,
            playableVideoIndices: playableVideoIndices
        )
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

/// One live Grid tile. Like BrowserRow, it observes the store directly because
/// macOS lazy containers can retain an already-created value subtree after the
/// shared per-file rating storage changes. Keeping the observation here makes
/// the badge, selection frame, and accessibility value update immediately.
private struct GridCell: View {
    private static let ratingBadgeSize: CGFloat = 21
    private static let ratingButtonSize: CGFloat = 40

    @ObservedObject var store: SessionStore
    let index: Int
    let onPointerCurrentChange: () -> Void

    var body: some View {
        if store.items.indices.contains(index) {
            let item = store.items[index]
            let actions = GridCellActions(
                store: store,
                index: index,
                onPointerCurrentChange: onPointerCurrentChange
            )
            VStack(spacing: 3) {
                ZStack {
                    ThumbnailView(
                        item: item,
                        isCurrent: index == store.currentIndex,
                        isSelected: store.selectedIndices.contains(index),
                        showsRatingBadge: false,
                        videoPlayback: store.videoPlayback
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    GridImmediateClickSurface(
                        onSingleClick: actions.selectPhoto,
                        onDoubleClick: actions.openInGallery
                    )
                        .mediaTileAccessibility(
                            item: item,
                            isCurrent: index == store.currentIndex,
                            isSelected: store.selectedIndices.contains(index),
                            showActionTitle: "Make Current",
                            show: {
                                actions.makeCurrent()
                            },
                            open: {
                                actions.openInGallery()
                            },
                            canRate: store.canRate,
                            rate: { rating in
                                store.rate(rating, at: index)
                            },
                            toggleSelection: {
                                store.toggleSelection(of: index)
                            }
                        )

                    if item.isVideo, item.videoIsPlayable {
                        Button {
                            if index != store.currentIndex { store.setIndex(index) }
                            store.videoPlayback.toggle(item)
                        } label: {
                            Image(systemName: store.videoPlayback.isActive(item) && store.videoPlayback.isPlaying
                                ? "pause.fill"
                                : "play.fill")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .tint(.black.opacity(0.62))
                        .foregroundStyle(.white)
                        .controlSize(.large)
                        .help(store.videoPlayback.isActive(item) && store.videoPlayback.isPlaying
                            ? "Pause video"
                            : "Play video")
                        .accessibilityLabel(store.videoPlayback.isActive(item) && store.videoPlayback.isPlaying
                            ? "Pause video"
                            : "Play video")
                    }
                }
                // Keep the rating control above the photo's selection gesture
                // so its click never falls through and changes two things.
                .overlay(alignment: .topTrailing) {
                    Button {
                        actions.cycleRating()
                    } label: {
                        RatingBadge(
                            rating: item.rating,
                            isMixed: item.hasMixedRatings,
                            size: Self.ratingBadgeSize
                        )
                        .frame(
                            width: Self.ratingButtonSize,
                            height: Self.ratingButtonSize
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canRate)
                    .padding(2)
                    .help("Change rating")
                    .accessibilityLabel("Change rating for \(item.displayName)")
                    .accessibilityValue(
                        MediaTileAccessibility.ratingDescription(
                            for: item.ratingState
                        )
                    )
                }
                .aspectRatio(1, contentMode: .fit)

                ZStack {
                    Text(item.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityHidden(true)

                    GridImmediateClickSurface(
                        onSingleClick: actions.selectPhoto,
                        onDoubleClick: actions.openInGallery
                    )
                    .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A native pointer surface that commits a single click on mouse-up without
/// waiting for AppKit's double-click interval. The former exclusive pair of
/// SwiftUI TapGestures deliberately delayed selection until the double-click
/// recognizer failed. Here the first click selects immediately; a second click
/// arrives with `clickCount == 2` and opens the already-selected item.
struct GridImmediateClickSurface: NSViewRepresentable {
    let onSingleClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        ClickView(
            onSingleClick: onSingleClick,
            onDoubleClick: onDoubleClick
        )
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    final class ClickView: NSView {
        private static let dragThresholdSquared: CGFloat = 8 * 8

        var onSingleClick: (NSEvent.ModifierFlags) -> Void
        var onDoubleClick: () -> Void
        private var mouseDownLocation: CGPoint?
        private var exceededDragThreshold = false

        init(
            onSingleClick: @escaping (NSEvent.ModifierFlags) -> Void,
            onDoubleClick: @escaping () -> Void
        ) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            // A photo click returns keyboard navigation to the session instead
            // of leaving Space/arrows owned by the last toolbar control.
            window?.makeFirstResponder(nil)
            mouseDownLocation = convert(event.locationInWindow, from: nil)
            exceededDragThreshold = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownLocation else { return }
            let current = convert(event.locationInWindow, from: nil)
            let dx = current.x - start.x
            let dy = current.y - start.y
            if dx * dx + dy * dy >= Self.dragThresholdSquared {
                exceededDragThreshold = true
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownLocation = nil
                exceededDragThreshold = false
            }
            guard let start = mouseDownLocation else { return }
            let end = convert(event.locationInWindow, from: nil)
            let dx = end.x - start.x
            let dy = end.y - start.y
            guard !exceededDragThreshold,
                  dx * dx + dy * dy < Self.dragThresholdSquared else {
                return
            }
            if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onSingleClick(event.modifierFlags)
            }
        }
    }
}

/// The actions shared by the Grid's pointer and accessibility entry points.
/// Keeping them separate from the view makes the hit-target behavior directly
/// regression-testable without duplicating SessionStore mutations in tests.
@MainActor
struct GridCellActions {
    let store: SessionStore
    let index: Int
    var onPointerCurrentChange: () -> Void = {}

    func makeCurrent() {
        store.setIndex(index)
    }

    func selectPhoto(
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        store.handleThumbnailClick(at: index, modifiers: modifiers) {
            if index != store.currentIndex {
                onPointerCurrentChange()
            }
            makeCurrent()
        }
    }

    func openInGallery() {
        makeCurrent()
        store.viewMode = .gallery
    }

    /// One native Button activation always advances the rating exactly once.
    /// AppKit's click count is deliberately irrelevant: photographers often
    /// cycle rapidly, and a second/third click is still an intentional input.
    func cycleRating() {
        guard store.canRate,
              store.items.indices.contains(index)
        else {
            return
        }
        let ratesExistingSelection =
            store.selectedIndices.count > 1
            && store.selectedIndices.contains(index)
        if !ratesExistingSelection, index != store.currentIndex {
            onPointerCurrentChange()
        }
        store.toggleRating(at: index)
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

/// Classifies the starting point of a Grid drag from the tile geometry already
/// needed for selection. Control locations are deterministic within each
/// square media tile, so this avoids one GeometryReader and preference value
/// per rendered control while keeping native Button drags out of rubber-band
/// selection.
enum GridRubberBandHitTest {
    /// The 40-point rating target plus its two-point outer padding on each side.
    private static let ratingControlRegionSize: CGFloat = 44
    /// Conservatively covers the native large circular Play button without
    /// making the surrounding photo difficult to use as a drag origin.
    private static let playbackControlRegionSize: CGFloat = 48

    static func shouldTrackCanvasDrag(
        startingAt point: CGPoint,
        tileFrames: [Int: CGRect],
        playableVideoIndices: Set<Int>
    ) -> Bool {
        guard let (index, tileFrame) = tileFrames.first(where: {
            $0.value.contains(point)
        }) else {
            // Gaps and padding are intentional selection-canvas origins.
            return true
        }

        // GridCell's media area is a square at the top of the cell; the
        // filename beneath it remains an ordinary selection-canvas target.
        let mediaFrame = CGRect(
            x: tileFrame.minX,
            y: tileFrame.minY,
            width: tileFrame.width,
            height: tileFrame.width
        )
        guard mediaFrame.contains(point) else { return true }

        let ratingFrame = CGRect(
            x: mediaFrame.maxX - ratingControlRegionSize,
            y: mediaFrame.minY,
            width: ratingControlRegionSize,
            height: ratingControlRegionSize
        )
        if ratingFrame.contains(point) { return false }

        if playableVideoIndices.contains(index) {
            let halfPlaybackSize = playbackControlRegionSize / 2
            let playbackFrame = CGRect(
                x: mediaFrame.midX - halfPlaybackSize,
                y: mediaFrame.midY - halfPlaybackSize,
                width: playbackControlRegionSize,
                height: playbackControlRegionSize
            )
            if playbackFrame.contains(point) { return false }
        }

        return true
    }
}
