import SwiftUI

struct XMPConflictResolverView: View {
    let conflicts: [XMPSameStemConflictDescriptor]
    let onCancel: () -> Void
    let onApply: ([XMPConflictResolutionRequest]) -> Void

    @State private var choices: [String: XMPConflictResolutionChoice]

    init(
        conflicts: [XMPSameStemConflictDescriptor],
        onCancel: @escaping () -> Void,
        onApply: @escaping ([XMPConflictResolutionRequest]) -> Void
    ) {
        self.conflicts = conflicts
        self.onCancel = onCancel
        self.onApply = onApply
        _choices = State(initialValue: Dictionary(
            uniqueKeysWithValues: conflicts.map { ($0.id, .skip) }
        ))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Resolve RAW + JPEG Metadata")
                .font(.title2.bold())
            Text("These same-name files have different Louppe metadata. Capture One and other sidecar workflows can store only one set in their shared XMP.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(conflicts) { conflict in
                        conflictRow(conflict)
                        if conflict.id != conflicts.last?.id { Divider() }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 210, maxHeight: 430)

            HStack {
                Text("Apply the same choice to all conflicts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Apply to All…") {
                    Button("Keep all separate") { applyToAll(.skip) }
                    Button("Use RAW metadata for all") { applyToAll(.useRAW) }
                    Button("Use JPEG metadata for all") { applyToAll(.useJPEG) }
                }
            }

            Text("Choosing RAW or JPEG changes the other file’s Louppe decision, stars, and color. The change is one undoable Louppe action; XMP is written only after a new plan is reviewed and confirmed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Resolutions") {
                    onApply(conflicts.map {
                        XMPConflictResolutionRequest(
                            conflict: $0,
                            choice: choices[$0.id] ?? .skip
                        )
                    })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasActionableChoice)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func conflictRow(
        _ conflict: XMPSameStemConflictDescriptor
    ) -> some View {
        let raw = conflict.rawMember
        let jpeg = conflict.jpegMember
        return VStack(alignment: .leading, spacing: 9) {
            Text(conflictTitle(conflict))
                .font(.headline)

            if let raw {
                metadataRow(raw, differing: conflict.differingDimensions)
            }
            if let jpeg {
                metadataRow(jpeg, differing: conflict.differingDimensions)
            }

            Picker(
                "Resolution for \(conflictTitle(conflict))",
                selection: choiceBinding(for: conflict.id)
            ) {
                Text("Keep separate and skip this XMP")
                    .tag(XMPConflictResolutionChoice.skip)
                Text("Use RAW metadata for both")
                    .tag(XMPConflictResolutionChoice.useRAW)
                    .accessibilityLabel(
                        "Use RAW metadata for both. Change \(jpeg?.filename ?? "the JPEG") to match \(raw?.filename ?? "the RAW")."
                    )
                Text("Use JPEG metadata for both")
                    .tag(XMPConflictResolutionChoice.useJPEG)
                    .accessibilityLabel(
                        "Use JPEG metadata for both. Change \(raw?.filename ?? "the RAW") to match \(jpeg?.filename ?? "the JPEG")."
                    )
            }
            .pickerStyle(.radioGroup)
        }
        .accessibilityElement(children: .contain)
    }

    private func metadataRow(
        _ member: XMPSameStemConflictDescriptor.Member,
        differing: Set<XMPMetadataDimension>
    ) -> some View {
        HStack(spacing: 10) {
            Text(member.role == .raw ? "RAW" : "JPEG")
                .font(.caption.weight(.semibold))
                .frame(width: 38, alignment: .leading)
            Text(member.filename)
                .lineLimit(1)
                .frame(minWidth: 130, alignment: .leading)
            metadataValue(
                decisionLabel(member.metadata.rating),
                differs: differing.contains(.decision)
            )
            metadataValue(
                starsLabel(member.metadata.starRating),
                differs: differing.contains(.stars)
            )
            metadataValue(
                colorLabel(member.metadata.colorLabel),
                differs: differing.contains(.color)
            )
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(member.role == .raw ? "RAW" : "JPEG"), \(member.filename), decision \(decisionLabel(member.metadata.rating)), \(starsLabel(member.metadata.starRating)), color \(colorLabel(member.metadata.colorLabel))"
        )
    }

    private func metadataValue(_ value: String, differs: Bool) -> some View {
        Text(value)
            .fontWeight(differs ? .semibold : .regular)
            .foregroundStyle(differs ? .primary : .secondary)
            .frame(minWidth: 72, alignment: .leading)
    }

    private func choiceBinding(
        for id: String
    ) -> Binding<XMPConflictResolutionChoice> {
        Binding(
            get: { choices[id] ?? .skip },
            set: { choices[id] = $0 }
        )
    }

    private var hasActionableChoice: Bool {
        choices.values.contains { $0 != .skip }
    }

    private func applyToAll(_ choice: XMPConflictResolutionChoice) {
        for conflict in conflicts { choices[conflict.id] = choice }
    }

    private func conflictTitle(
        _ conflict: XMPSameStemConflictDescriptor
    ) -> String {
        let name = conflict.rawMember?.filename
            ?? conflict.jpegMember?.filename
            ?? "RAW + JPEG"
        return (name as NSString).deletingPathExtension
    }

    private func decisionLabel(_ rating: Rating) -> String {
        switch rating {
        case .yes: return "Yes"
        case .no: return "No"
        case .undecided: return "Undecided"
        }
    }

    private func starsLabel(_ rating: StarRating?) -> String {
        guard let rating else { return "Unrated" }
        return rating == .one ? "1 star" : "\(rating.count) stars"
    }

    private func colorLabel(_ label: PhotoColorLabel?) -> String {
        label?.displayName ?? "None"
    }
}
