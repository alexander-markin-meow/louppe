import SwiftUI

/// The "browser": a vertical column of thumbnails along the left edge of the
/// culling view, with thin separator lines between different shooting days.
struct FilmstripView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 6) {
                            if store.startsNewDay(at: index) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(.secondary.opacity(0.5))
                                    .frame(width: 64, height: 2)
                                    .padding(.vertical, 3)
                            }
                            ThumbnailView(item: item, isCurrent: index == store.currentIndex)
                                .frame(width: 102, height: 102)
                                .onTapGesture {
                                    store.setIndex(index)
                                }
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: store.currentIndex) {
                if let item = store.currentItem {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let item = store.currentItem {
                    proxy.scrollTo(item.id, anchor: .center)
                }
            }
        }
    }
}
