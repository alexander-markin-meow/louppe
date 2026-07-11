import SwiftUI

struct MainCullingView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            if store.showFilmstrip {
                FilmstripView(store: store)
                    .frame(width: 122)
                    .background(Color.appBackground)
                    .transition(.move(edge: .leading))
            }

            ZStack {
                Color.appBackground
                if let item = store.currentItem {
                    FullImageView(item: item, zoomMode: $store.zoomMode)
                        .id(item.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.showMetadataPanel, let item = store.currentItem {
                Divider()
                MetadataPanel(item: item)
                    .frame(width: 240)
                    .transition(.move(edge: .trailing))
            }
        }
    }
}

/// Vertical column of thumbnails along the left edge.
struct FilmstripView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 6) {
                            if startsNewDay(at: index) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(.secondary.opacity(0.5))
                                    .frame(width: 64, height: 2)
                                    .padding(.vertical, 3)
                            }
                            ThumbnailView(item: item, isCurrent: index == store.currentIndex)
                                .frame(width: 102, height: 70)
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

    /// True when this photo was taken on a different day than the one above it.
    private func startsNewDay(at index: Int) -> Bool {
        guard index > 0 else { return false }
        guard let previous = store.items[index - 1].captureDate,
              let current = store.items[index].captureDate else { return false }
        return !Calendar.current.isDate(previous, inSameDayAs: current)
    }
}

struct MetadataPanel: View {
    let item: PhotoItem

    @State private var fields: [MetadataField] = []

    // The exposure triangle, shown as a horizontal row at the top.
    private let exposureLabels = ["Aperture", "Shutter", "ISO"]

    private var exposureFields: [MetadataField] {
        exposureLabels.compactMap { label in fields.first { $0.label == label } }
    }

    private var otherFields: [MetadataField] {
        fields.filter { !exposureLabels.contains($0.label) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Info")
                        .font(.headline)
                    Spacer()
                    RatingBadge(rating: item.rating)
                }
                Divider()

                if !exposureFields.isEmpty {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(exposureFields) { field in
                            VStack(spacing: 2) {
                                Text(field.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(field.value)
                                    .font(.callout.weight(.medium))
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Divider()
                }

                ForEach(otherFields) { field in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(field.value)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .task(id: item.id) {
            let current = item
            let loaded = await Task.detached(priority: .userInitiated) {
                MetadataExtractor.fields(for: current)
            }.value
            if !Task.isCancelled {
                fields = loaded
            }
        }
    }
}
