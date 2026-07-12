import SwiftUI

/// The contact-sheet grid: click to cycle a photo's rating, double-click to
/// open it in the culling view. Days are separated by a horizontal line and
/// each day starts on a fresh row. ⌘+/⌘− resize the tiles.
struct LightTableView: View {
    @ObservedObject var store: SessionStore

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: store.gridThumbSize, maximum: store.gridThumbSize * 1.4), spacing: 10)]
    }

    /// Photos grouped into runs of consecutive same-day shots, in session
    /// order. Each group renders as its own grid, so a new day always starts
    /// on a fresh row. Each element keeps its global index for rating/jumping.
    private var dayGroups: [[(index: Int, item: PhotoItem)]] {
        var groups: [[(index: Int, item: PhotoItem)]] = []
        for (i, item) in store.items.enumerated() {
            if i == 0 || store.startsNewDay(at: i) {
                groups.append([])
            }
            groups[groups.count - 1].append((i, item))
        }
        return groups
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
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
            ThumbnailView(item: item, isCurrent: index == store.currentIndex)
                .aspectRatio(1, contentMode: .fit)
            Text(item.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .id(item.id)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2).onEnded {
                // Double-click: open in the main culling view.
                store.setIndex(index)
                store.viewMode = .culling
            }
            .exclusively(before: TapGesture(count: 1).onEnded {
                // Single click: cycle undecided → yes → no.
                store.setIndex(index)
                store.toggleRating(at: index)
            })
        )
    }
}
