import SwiftUI

/// The Browser: an optional vertical column of thumbnails along the left edge
/// of the Gallery view, with thin separators between shooting days.
struct BrowserView: View {
    /// Keep the original 122-point thumbnail column and add exactly enough
    /// room for a native non-overlay scrollbar beside it.
    static let width = 122 + PersistentVerticalScroller.gutterWidth

    @ObservedObject var store: SessionStore
    @State private var followTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(store.visibleIndices, id: \.self) { index in
                        if store.items.indices.contains(index) {
                            let item = store.items[index]
                            VStack(spacing: 6) {
                                if store.visibleDayStartIndices.contains(index) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(.secondary.opacity(0.5))
                                        .frame(width: 64, height: 2)
                                        .padding(.vertical, 3)
                                }
                                ThumbnailView(
                                    item: item,
                                    isCurrent: index == store.currentIndex,
                                    isSelected: store.selectedIndices.contains(index)
                                )
                                .frame(width: 102, height: 102)
                                .onTapGesture {
                                    // ⇧-click: range · ⌘-click: add/remove · click: jump.
                                    store.handleThumbnailClick(at: index) {
                                        store.setIndex(index)
                                    }
                                }
                            }
                            .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(PersistentVerticalScroller())
            }
            .onChange(of: store.currentIndex) {
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
        }
    }
}
