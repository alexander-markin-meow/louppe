import SwiftUI

/// The Browser: an optional vertical column of thumbnails along the left edge
/// of the Gallery view, with a small gray group label above each sort group
/// (shooting day, camera, subfolder… depending on the active sort key).
struct BrowserView: View {
    /// Keep the original 122-point thumbnail column and add exactly enough
    /// room for a native non-overlay scrollbar beside it.
    static let width = 122 + PersistentVerticalScroller.gutterWidth

    @ObservedObject var store: SessionStore
    @State private var followTask: Task<Void, Never>?
    /// A plain click targets a thumbnail that is already on screen, so the
    /// follow-scroll that click's index change triggers must be skipped —
    /// centering the clicked thumbnail drags the strip under the cursor.
    /// Keyboard navigation keeps following as before.
    @State private var suppressNextFollow = false

    /// Structural removals can put a different item at the same numeric
    /// index. Key Browser rows by the media id so SwiftUI never reuses the
    /// removed item's selection state for its successor.
    private struct Entry: Identifiable {
        let id: String
        let index: Int
    }

    private var visibleEntries: [Entry] {
        store.visibleIndices.compactMap { index in
            guard store.items.indices.contains(index) else { return nil }
            return Entry(id: store.items[index].id, index: index)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(visibleEntries) { entry in
                        BrowserRow(store: store, index: entry.index) {
                            // Only set when the click will actually move
                            // currentIndex, so the flag is always consumed
                            // by the onChange it precedes.
                            if entry.index != store.currentIndex {
                                suppressNextFollow = true
                            }
                            store.setIndex(entry.index)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(PersistentVerticalScroller())
            }
            // The current item's id can change while its numeric index stays
            // the same after Clean Up or Move export.
            .onChange(of: store.currentItem?.id) {
                if suppressNextFollow {
                    suppressNextFollow = false
                    return
                }
                followCurrentPhoto(using: proxy, animated: true)
            }
            .onAppear {
                followCurrentPhoto(using: proxy, animated: false)
            }
            .onDisappear {
                followTask?.cancel()
            }
        }
    }

    private func followCurrentPhoto(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = store.currentItem?.id else { return }
        followTask?.cancel()
        followTask = Task { @MainActor in
            // Let the current-index update reach the lazy stack before asking
            // it to resolve an item that may start outside the viewport.
            await Task.yield()
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
            // Lazy stacks estimate distant offsets, so a long jump can land
            // off-center. Issue a second pass once the target row exists —
            // the same correction the Grid view applies.
            await Task.yield()
            guard !Task.isCancelled, store.currentItem?.id == id else { return }
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// One Browser strip row. It observes the store directly: the LazyVStack's
/// diff of already-created rows is not a reliable invalidation path on macOS
/// (rows froze their badges and current-photo frame until the view was
/// recreated, most visibly after Clear All Ratings), so a row must never
/// depend on the container to learn about store changes. Do not turn this
/// back into a plain value subtree.
private struct BrowserRow: View {
    @ObservedObject var store: SessionStore
    let index: Int
    /// Runs on an unmodified click; the parent supplies it so the
    /// suppress-follow flag stays BrowserView @State.
    let onPlainClick: () -> Void

    var body: some View {
        // The bounds check stays inside the row: it re-renders independently
        // of the parent, and visibleIndices must never outlive items.
        if store.items.indices.contains(index) {
            let item = store.items[index]
            VStack(spacing: 6) {
                if let title = store.visibleGroupTitles[index] {
                    // Same header shape as the Grid: name first,
                    // divider filling whatever width is left.
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.secondary.opacity(0.5))
                            .frame(height: 2)
                    }
                    .frame(width: 102)
                    .padding(.vertical, 3)
                }
                ThumbnailView(
                    item: item,
                    isCurrent: item.id == store.currentItem?.id,
                    isSelected: store.selectedIndices.contains(index)
                )
                .frame(width: 102, height: 102)
                .onTapGesture {
                    // ⇧-click: range · ⌘-click: add/remove · click: jump.
                    store.handleThumbnailClick(at: index, plainClick: onPlainClick)
                }
            }
            // Keep the String identity as the follow-scroll target.
            .id(item.id)
        }
    }
}
