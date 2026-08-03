import SwiftUI

/// The one-photo-at-a-time Gallery view: Browser column and large photo pane.
/// SessionView owns the shared trailing Info panel so switching modes does not
/// restart its metadata and histogram work.
struct GalleryView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            if store.showBrowser {
                BrowserView(store: store)
                    .frame(width: BrowserView.width)
                    .background(Color.appBackground)
                    .transition(.move(edge: .leading))
            }

            ZStack {
                Color.appBackground
                if store.items.isEmpty {
                    SessionEmptyView(
                        reason: store.emptySessionReason,
                        canUndo: store.canUndo
                    )
                } else if store.visibleIndices.isEmpty && store.filter.isActive {
                    ContentUnavailableView(
                        "No items match the filter",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust or reset the filter in the toolbar to see media again.")
                    )
                } else if let item = store.currentItem {
                    if item.isVideo {
                        GalleryVideoPlayerView(item: item, playback: store.videoPlayback)
                    } else {
                        FullImageView(
                            item: item,
                            zoomMode: $store.zoomMode,
                            showsClippingWarnings:
                                store.showClippingWarnings
                                && store.selectedIndices.count <= 1,
                            actualSizeViewport: store.actualSizeViewport,
                            onZoomToActual: { position in
                                store.zoomToActual(at: position)
                            },
                            onZoomToFit: {
                                store.zoomToFit()
                            }
                        ) { loading in
                            store.fullImageLoads += loading ? 1 : -1
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SessionRenderMarker(kind: .gallery))
    }
}
