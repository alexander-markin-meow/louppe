import SwiftUI

/// The one-photo-at-a-time Gallery view:
/// Browser column · large photo pane · info panel.
struct GalleryView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            if store.showBrowser {
                BrowserView(store: store)
                    .frame(width: 122)
                    .background(Color.appBackground)
                    .transition(.move(edge: .leading))
            }

            ZStack {
                Color.appBackground
                if store.items.isEmpty {
                    // Only reachable when Clean Up emptied the whole session
                    // (an empty scan goes back to the welcome screen instead).
                    ContentUnavailableView(
                        "No photos left in this folder",
                        systemImage: "trash",
                        description: Text("Everything was moved to the Trash. Press ⌘Z to put the photos back.")
                    )
                } else if store.visibleIndices.isEmpty && store.filter.isActive {
                    ContentUnavailableView(
                        "No photos match the filter",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust or reset the filter in the toolbar to see photos again.")
                    )
                } else if let item = store.currentItem {
                    FullImageView(item: item, zoomMode: $store.zoomMode) { loading in
                        store.fullImageLoads += loading ? 1 : -1
                    }
                    .id(item.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.showMetadataPanel, let item = store.currentItem {
                Divider()
                MetadataPanel(store: store, item: item)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing))
            }
        }
    }
}
