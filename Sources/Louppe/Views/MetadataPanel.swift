import SwiftUI

/// The info panel: filename and rating, photo histogram, camera/lens, shooting
/// settings, then the remaining EXIF fields.
struct MetadataPanel: View {
    /// EXIF detail and histogram analysis are secondary to the visible photo.
    /// A short dwell prevents key repeat from opening every transient file.
    private static let inspectionDebounceNanoseconds: UInt64 = 80_000_000

    @ObservedObject var store: SessionStore
    let item: PhotoItem

    @State private var fields: [MetadataField] = []
    @State private var fieldsRevision: PhotoContentRevision?
    @State private var histogram: HistogramAnalysis?
    @State private var histogramLoadFailed = false
    @State private var histogramRevision: PhotoContentRevision?

    private struct MetadataLoadID: Hashable {
        let contentRevision: PhotoContentRevision
        let isMultipleSelection: Bool
    }

    private struct HistogramLoadID: Hashable {
        let contentRevision: PhotoContentRevision
        let isEligible: Bool
    }

    private let shootingLabels = ["Aperture", "Shutter", "ISO"]
    private let secondaryShootingLabels = ["Focal length", "Exposure comp.", "White balance"]
    private let promotedLabels = [
        "Filename", "Camera", "Lens", "Aperture", "Shutter", "ISO",
        "Focal length", "Exposure comp.", "White balance"
    ]

    private var displayedFields: [MetadataField] {
        fieldsRevision == item.contentRevision ? fields : []
    }

    private var displayedHistogram: HistogramAnalysis? {
        histogramRevision == item.contentRevision ? histogram : nil
    }

    private var displayedHistogramLoadFailed: Bool {
        histogramRevision == item.contentRevision && histogramLoadFailed
    }

    private var cameraName: String? {
        displayedFields.first { $0.label == "Camera" }?.value
    }

    private var lensName: String? {
        displayedFields.first { $0.label == "Lens" }?.value
    }

    private var primaryShootingFields: [MetadataField] {
        fields(for: shootingLabels)
    }

    private var secondaryShootingFields: [MetadataField] {
        fields(for: secondaryShootingLabels)
    }

    private var hasCameraLensInfo: Bool {
        cameraName != nil || lensName != nil
    }

    private var hasShootingInfo: Bool {
        !primaryShootingFields.isEmpty || !secondaryShootingFields.isEmpty
    }

    private var cameraLensText: String? {
        switch (cameraName, lensName) {
        case let (camera?, lens?): return "\(camera) + \(lens)"
        case let (camera?, nil): return camera
        case let (nil, lens?): return lens
        case (nil, nil): return nil
        }
    }

    private func fields(for labels: [String]) -> [MetadataField] {
        labels.compactMap { label in
            displayedFields.first { $0.label == label }
        }
    }

    private var otherFields: [MetadataField] {
        displayedFields.filter { !promotedLabels.contains($0.label) }
    }

    private var multiSelectionSummary: PhotoSelectionSummary? {
        guard store.selectedIndices.count > 1 else { return nil }
        let selectedItems = store.selectedIndices.sorted().compactMap { index in
            store.items.indices.contains(index) ? store.items[index] : nil
        }
        guard selectedItems.count > 1 else { return nil }
        return PhotoSelectionSummary(items: selectedItems)
    }

    private var metadataLoadID: MetadataLoadID {
        MetadataLoadID(
            contentRevision: item.contentRevision,
            isMultipleSelection: store.selectedIndices.count > 1
        )
    }

    private var showsHistogram: Bool {
        store.selectedIndices.count <= 1
            && item.mediaKind == .photo
            && item.isSupported
    }

    private var histogramLoadID: HistogramLoadID {
        HistogramLoadID(
            contentRevision: item.contentRevision,
            isEligible: showsHistogram
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let multiSelectionSummary {
                    multiSelectionContent(multiSelectionSummary)
                } else {
                    singlePhotoContent
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .background(SessionRenderMarker(kind: .metadata))
        .task(id: metadataLoadID) {
            let requestedRevision = metadataLoadID.contentRevision
            fields = []
            fieldsRevision = requestedRevision
            guard !metadataLoadID.isMultipleSelection else {
                // The selection summary uses scan-cached metadata only. Avoid
                // reopening the current file for fields that are not rendered.
                return
            }
            try? await Task.sleep(
                nanoseconds: Self.inspectionDebounceNanoseconds
            )
            guard !Task.isCancelled else { return }
            let current = item
            let loaded = await Task.detached(priority: .userInitiated) {
                MetadataExtractor.fields(for: current)
            }.value
            guard !Task.isCancelled,
                  fieldsRevision == requestedRevision else { return }
            fields = loaded
        }
        .task(id: histogramLoadID) {
            let requestedRevision = histogramLoadID.contentRevision
            histogram = nil
            histogramLoadFailed = false
            histogramRevision = requestedRevision
            guard histogramLoadID.isEligible else { return }
            try? await Task.sleep(
                nanoseconds: Self.inspectionDebounceNanoseconds
            )
            guard !Task.isCancelled else { return }
            let requestedItem = item
            let loaded = await HistogramPipeline.shared.analysis(
                for: requestedItem
            )
            guard !Task.isCancelled,
                  histogramRevision == requestedRevision else { return }
            histogram = loaded
            histogramLoadFailed = (loaded == nil)
        }
    }

    // MARK: - Single photo

    @ViewBuilder
    private var singlePhotoContent: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(item.displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Button {
                store.toggleRating(at: store.currentIndex)
            } label: {
                RatingBadge(
                    rating: item.rating,
                    isMixed: item.hasMixedRatings,
                    size: 27
                )
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!store.canRate)
            .accessibilityLabel("Change Rating")
            .accessibilityValue(ratingDescription)
            .help("Change rating")
        }

        if showsHistogram {
            HistogramSection(
                analysis: displayedHistogram,
                loadFailed: displayedHistogramLoadFailed,
                store: store
            )

            if hasCameraLensInfo || hasShootingInfo || !otherFields.isEmpty {
                Divider()
            }
        }

        if let cameraLensText {
            metadataValue(cameraLensText, emphasized: true)
        }

        if hasCameraLensInfo && hasShootingInfo {
            Divider()
        }

        if hasShootingInfo {
            VStack(spacing: 12) {
                if !primaryShootingFields.isEmpty {
                    metadataRow(primaryShootingFields, showLabels: false, emphasized: true)
                }
                if !secondaryShootingFields.isEmpty {
                    metadataRow(secondaryShootingFields)
                }
            }
        }

        if hasShootingInfo && !otherFields.isEmpty {
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

    // MARK: - Multiple photos

    @ViewBuilder
    private func multiSelectionContent(_ summary: PhotoSelectionSummary) -> some View {
        Text(selectionTitle(for: summary))
            .font(.title3.weight(.semibold))

        Divider()

        selectionSummaryField("Cameras", value: summary.cameras.joined(separator: ", "))
        selectionSummaryField("Lenses", value: summary.lenses.joined(separator: ", "))
        selectionSummaryField("Captured", value: captureDateText(for: summary))
        selectionSummaryField(
            "Total size",
            value: ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)
        )
        selectionSummaryField("Types", value: summary.fileTypes.joined(separator: ", "))
    }

    private func selectionTitle(for summary: PhotoSelectionSummary) -> String {
        let itemLabel = summary.videoCount == 0 ? "photos" : "media items"
        return "\(summary.count) \(itemLabel) selected · \(summary.fileCount) files"
    }

    private func selectionSummaryField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 3)
    }

    private func captureDateText(for summary: PhotoSelectionSummary) -> String {
        var lines: [String] = []
        if let range = summary.captureDayRange {
            if range.lowerBound == range.upperBound {
                lines.append(AppDateFormat.day(range.lowerBound))
            } else {
                lines.append(AppDateFormat.dayRange(
                    from: range.lowerBound,
                    to: range.upperBound
                ))
            }
        }
        if summary.unknownDateCount > 0 {
            let itemLabel = summary.videoCount == 0 ? "photo" : "media item"
            let label = summary.unknownDateCount == 1
                ? "1 \(itemLabel) without a capture date"
                : "\(summary.unknownDateCount) \(itemLabel)s without a capture date"
            lines.append(label)
        }
        return lines.isEmpty ? "Unknown" : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func metadataRow(
        _ rowFields: [MetadataField],
        showLabels: Bool = true,
        emphasized: Bool = false
    ) -> some View {
        if !rowFields.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                ForEach(rowFields) { field in
                    VStack(spacing: 2) {
                        if showLabels {
                            Text(displayLabel(for: field))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if emphasized {
                            settingValue(for: field)
                        } else {
                            Text(field.value)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(valueColor(for: field))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func settingValue(for field: MetadataField) -> some View {
        let color = valueColor(for: field)
        let largeFont = Font.system(size: 18, weight: .semibold)
        let smallFont = Font.system(size: 12, weight: .semibold)
        let value = field.value

        switch field.label {
        case "Aperture" where value.hasPrefix("f/"):
            return Text("f/\(Text(String(value.dropFirst(2))).font(largeFont))")
                .font(smallFont)
                .foregroundStyle(color)
                .lineLimit(1)
                .textSelection(.enabled)
        case "Shutter" where value.hasPrefix("1/"):
            let remainder = String(value.dropFirst(2))
            let suffix = remainder.hasSuffix("s") ? "s" : ""
            let number = suffix.isEmpty ? remainder : String(remainder.dropLast())
            return Text("1/\(Text(number).font(largeFont))\(suffix)")
                .font(smallFont)
                .foregroundStyle(color)
                .lineLimit(1)
                .textSelection(.enabled)
        case "ISO":
            return Text("ISO\(Text(value).font(largeFont))")
                .font(smallFont)
                .foregroundStyle(color)
                .lineLimit(1)
                .textSelection(.enabled)
        default:
            return Text(value)
                .font(largeFont)
                .foregroundStyle(color)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private func displayLabel(for field: MetadataField) -> String {
        switch field.label {
        case "Exposure comp.": return "Exp. comp."
        case "White balance": return "WB"
        default: return field.label
        }
    }

    private func metadataValue(_ value: String, emphasized: Bool = false) -> some View {
        Text(value)
            .font(emphasized ? .subheadline : .callout)
            .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
    }

    private func valueColor(for field: MetadataField) -> Color {
        guard field.label == "ISO", Int(field.value) ?? 0 > 6000 else { return .primary }
        return .red.opacity(0.72)
    }

    private var ratingDescription: String {
        if item.hasMixedRatings { return "Mixed" }
        switch item.rating {
        case .yes: return "Yes"
        case .no: return "No"
        case .undecided: return "Undecided"
        }
    }
}
