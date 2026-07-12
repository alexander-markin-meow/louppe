import SwiftUI

/// The info panel: filename header, camera name, the exposure triangle
/// (aperture/shutter/ISO) in a row, then the remaining EXIF fields.
struct MetadataPanel: View {
    let item: PhotoItem

    @State private var fields: [MetadataField] = []

    // The exposure triangle, shown as a horizontal row at the top.
    private let exposureLabels = ["Aperture", "Shutter", "ISO"]

    // Promoted into the header area, so left out of the field column below.
    private let headerLabels = ["Filename", "Camera"]

    private var exposureFields: [MetadataField] {
        exposureLabels.compactMap { label in fields.first { $0.label == label } }
    }

    private var otherFields: [MetadataField] {
        fields.filter { !exposureLabels.contains($0.label) && !headerLabels.contains($0.label) }
    }

    private var cameraName: String? {
        fields.first { $0.label == "Camera" }?.value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    RatingBadge(rating: item.rating)
                }

                if let cameraName {
                    Text(cameraName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
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
