import SwiftUI

struct ExportView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var exporter = ExportManager()
    // The sheet's content is recreated per presentation, so every open starts
    // from the safe default: Copy, keepers only.
    @State private var mode: ExportMode = .copy
    @State private var selectedRatings: Set<Rating> = [.yes]
    @State private var selectedStars = ExportSelectionPredicate.allStarStates
    @State private var selectedColors = ExportSelectionPredicate.allColorStates
    @State private var selectionSnapshot = ExportSelectionSnapshot.empty
    @State private var xmpProfile: XMPApplicationProfile = .universal
    @State private var universalDecisionKeywords = false
    @State private var allowExternalLabelReplacement = false
    @State private var showXMPDetails = false
    @State private var xmpInclusionChoice = ExportXMPInclusionChoice()
    @State private var existingXMPCount = 0
    @State private var excludedACRCompanionCount = 0
    @State private var isCheckingExistingXMP = false
    @State private var xmpInspectionID = UUID()
    @State private var xmpInspectionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            if mode == .metadataXMP {
                xmpContent
            } else {
                switch exporter.state {
                case .summary:
                    summaryView
                case .preparingXMP(let mode):
                    xmpExportPreparationView(mode: mode)
                case .awaitingXMPConfirmation(let confirmation):
                    xmpExportPreflightView(confirmation)
                case .working(let mode, let done, let total):
                    workingView(mode: mode, done: done, total: total)
                case .finished(let outcome):
                    finishedView(outcome: outcome)
                case .failed(let message):
                    failedView(message: message)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            xmpInclusionChoice = ExportXMPInclusionChoice()
            existingXMPCount = 0
            excludedACRCompanionCount = 0
            refreshSelectionSnapshot()
        }
        .onDisappear {
            xmpInspectionTask?.cancel()
            exporter.reset()
            store.resetXMPPublication()
        }
        .onChange(of: mode) {
            showXMPDetails = false
            store.resetXMPPublication()
            refreshSelectionSnapshot()
        }
        .onChange(of: selectedRatings) { refreshSelectionSnapshot() }
        .onChange(of: selectedStars) { refreshSelectionSnapshot() }
        .onChange(of: selectedColors) { refreshSelectionSnapshot() }
        .onChange(of: store.items.count) { refreshSelectionSnapshot() }
    }

    private var isWorking: Bool {
        if store.isXMPPublicationRunning { return true }
        if case .preparingXMP = exporter.state { return true }
        if case .working = exporter.state { return true }
        return false
    }

    private var summaryView: some View {
        VStack(spacing: 14) {
            Text("Export")
                .font(.title2.bold())

            Picker("Mode", selection: $mode) {
                Text("Copy").tag(ExportMode.copy)
                Text("Move").tag(ExportMode.move)
                Text("Metadata (XMP)").tag(ExportMode.metadataXMP)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 10) {
                Text("Photos to include")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 12) {
                    ratingTile(.yes, count: store.yesCount, label: "Yes", color: .green)
                    ratingTile(.no, count: store.noCount, label: "No", color: .red)
                    ratingTile(.undecided, count: store.undecidedCount, label: "Undecided", color: .secondary)
                }

                exportMenuRow("Stars") {
                    Menu(starSelectionSummary) {
                        Toggle(
                            "Unrated",
                            isOn: membershipBinding(
                                .unrated,
                                in: $selectedStars
                            )
                        )
                        ForEach(StarRating.allCases, id: \.self) { rating in
                            Toggle(
                                rating == .one
                                    ? "1 star"
                                    : "\(rating.count) stars",
                                isOn: membershipBinding(
                                    .stars(rating),
                                    in: $selectedStars
                                )
                            )
                        }
                        Toggle(
                            "Mixed",
                            isOn: membershipBinding(.mixed, in: $selectedStars)
                        )
                    }
                    .accessibilityLabel("Star ratings")
                    .accessibilityValue(starSelectionSummary)
                }

                exportMenuRow("Color") {
                    Menu(colorSelectionSummary) {
                        Toggle(
                            "None",
                            isOn: membershipBinding(
                                .none,
                                in: $selectedColors
                            )
                        )
                        ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                            Toggle(
                                isOn: membershipBinding(
                                    .label(label),
                                    in: $selectedColors
                                )
                            ) {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(label.swatchColor)
                                        .frame(width: 10, height: 10)
                                    Text(label.displayName)
                                }
                            }
                        }
                        Toggle(
                            "Mixed",
                            isOn: membershipBinding(.mixed, in: $selectedColors)
                        )
                    }
                    .accessibilityLabel("Color labels")
                    .accessibilityValue(colorSelectionSummary)
                }
            }

            if mode == .metadataXMP {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    exportMenuRow("Application") {
                        Picker("Application", selection: $xmpProfile) {
                            ForEach(XMPApplicationProfile.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                    }
                    if xmpProfile == .universal {
                        Toggle(
                            "Make decisions visible as keywords",
                            isOn: $universalDecisionKeywords
                        )
                    }
                    Toggle(
                        "Allow replacing or removing external color labels",
                        isOn: $allowExternalLabelReplacement
                    )
                    if allowExternalLabelReplacement {
                        Text("Confirmed: an external xmp:Label may be replaced or removed when it conflicts with the selected Louppe color.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Write current Louppe metadata beside the original photos. Original media is never modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Include XMP sidecars",
                        isOn: includeXMPBinding
                    )

                    Text(copyMoveXMPExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if excludedACRCompanionCount > 0 {
                        Text("\(excludedACRCompanionCount) Lightroom .acr companion\(excludedACRCompanionCount == 1 ? "" : "s") will not be included and will remain in the source folder.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if xmpInclusionChoice.isIncluded {
                        exportMenuRow("Application") {
                            Picker("Application", selection: $xmpProfile) {
                                ForEach(XMPApplicationProfile.allCases, id: \.self) {
                                    Text($0.displayName).tag($0)
                                }
                            }
                        }
                        if xmpProfile == .universal {
                            Toggle(
                                "Make decisions visible as keywords",
                                isOn: $universalDecisionKeywords
                            )
                        }
                        Toggle(
                            "Allow replacing or removing external color labels",
                            isOn: $allowExternalLabelReplacement
                        )
                        if allowExternalLabelReplacement {
                            Text("Confirmed: an external xmp:Label may be replaced or removed when it conflicts with the selected Louppe color.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Text(exportDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if mode == .move {
                Text("Moved items leave the source folder and this session. This can't be undone in Louppe — the files stay safe at the destination.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if selectionSnapshot.mixedDecisionCount > 0 {
                Text("\(selectionSnapshot.mixedDecisionCount) included RAW+JPEG pair\(selectionSnapshot.mixedDecisionCount == 1 ? " has" : "s have") different file decisions and \(selectionSnapshot.mixedDecisionCount == 1 ? "is" : "are") treated as undecided.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if store.mixedStarCount > 0 || store.mixedColorCount > 0 {
                Text(mixedMetadataNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if store.undecidedCount > 0 && !selectedRatings.contains(.undecided) {
                Text("\(store.undecidedCount) item\(store.undecidedCount == 1 ? "" : "s") still undecided — they won't be exported.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { store.isExportPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .metadataXMP ? "Write Sidecars" : "Choose Destination…") {
                    if mode == .metadataXMP {
                        store.prepareXMPPublication(
                            selected: selectionSnapshot.selectedItems(from: store.items),
                            profile: xmpProfile,
                            visibleDecisionKeywords: effectiveVisibleDecisionKeywords,
                            allowExternalLabelReplacement: allowExternalLabelReplacement
                        )
                    } else {
                        exporter.promptDestinationAndExport(
                            sourceFolder: store.sourceFolder,
                            selected: selectionSnapshot.selectedItems(from: store.items),
                            familyContextItems: store.items,
                            mode: mode,
                            includeXMP: xmpInclusionChoice.isIncluded,
                            xmpProfile: xmpProfile,
                            visibleDecisionKeywords: effectiveVisibleDecisionKeywords,
                            allowExternalLabelReplacement: allowExternalLabelReplacement,
                            onOperationWillStart: { store.exportWillStart(mode: $0) },
                            onOperationDidFinish: {
                                store.finishExport(
                                    mode: $0,
                                    movedIDs: $1,
                                    requiresRecovery: $2,
                                    interruptionMessage: $3
                                )
                            }
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectionSnapshot.itemCount == 0
                        || (mode != .metadataXMP && isCheckingExistingXMP)
                )
            }
        }
    }

    private var selectionPredicate: ExportSelectionPredicate {
        ExportSelectionPredicate(
            decisions: selectedRatings,
            starStates: selectedStars,
            colorStates: selectedColors
        )
    }

    private func refreshSelectionSnapshot() {
        selectionSnapshot = ExportSelectionSnapshot(
            items: store.items,
            predicate: selectionPredicate
        )
        scheduleXMPInspection()
    }

    private var includeXMPBinding: Binding<Bool> {
        Binding {
            xmpInclusionChoice.isIncluded
        } set: { value in
            xmpInclusionChoice.setManually(value)
        }
    }

    private func scheduleXMPInspection() {
        xmpInspectionTask?.cancel()
        guard mode != .metadataXMP else {
            isCheckingExistingXMP = false
            excludedACRCompanionCount = 0
            return
        }
        let requestID = UUID()
        xmpInspectionID = requestID
        isCheckingExistingXMP = true
        let selected = selectionSnapshot.selectedItems(from: store.items)
        let context = store.items
        xmpInspectionTask = Task {
            let inspection = await Task.detached(priority: .utility) {
                try? XMPExportPlanner.inspectSources(
                    selected: selected,
                    familyContextItems: context
                )
            }.value
            guard !Task.isCancelled, xmpInspectionID == requestID else {
                return
            }
            existingXMPCount = inspection?.recognizedPacketCount ?? 0
            excludedACRCompanionCount =
                inspection?.excludedACRCompanionCount ?? 0
            isCheckingExistingXMP = false
            xmpInclusionChoice.applyRecognizedPacketCount(existingXMPCount)
        }
    }

    private var copyMoveXMPExplanation: String {
        if isCheckingExistingXMP {
            return "Checking the selected photos for existing XMP sidecars…"
        }
        if xmpInclusionChoice.isIncluded {
            return "Existing sidecars will be included; missing ones will be created."
        }
        if existingXMPCount > 0 {
            return mode == .move
                ? "Existing XMP sidecars will remain in the source folder."
                : "Existing sidecars will stay at the source and will not be copied."
        }
        return "No existing XMP sidecars found. Turn on to create them."
    }

    private var exportDescription: String {
        if selectedRatings.isEmpty {
            return "Select at least one decision tile above to export."
        }
        if selectedStars.isEmpty {
            return "Select at least one star rating to export."
        }
        if selectedColors.isEmpty {
            return "Select at least one color label to export."
        }
        if selectionSnapshot.itemCount == 0 {
            return selectedRatings == [.yes]
                && selectedStars == ExportSelectionPredicate.allStarStates
                && selectedColors == ExportSelectionPredicate.allColorStates
                ? "Mark some items Yes (press F) before exporting."
                : "No items match all selected metadata."
        }
        let verb: String
        switch mode {
        case .copy: verb = "copied"
        case .move: verb = "moved"
        case .metadataXMP: verb = "prepared for XMP publication"
        }
        var text = "\(selectionSnapshot.itemCount) item\(selectionSnapshot.itemCount == 1 ? "" : "s") will be \(verb)"
        if selectionSnapshot.physicalFileCount != selectionSnapshot.itemCount {
            text += " (\(selectionSnapshot.physicalFileCount) files, including RAW+JPEG pairs)"
        }
        text += mode == .copy || mode == .metadataXMP
            ? ". Originals are never touched."
            : "."
        return text
    }

    private var effectiveVisibleDecisionKeywords: Bool {
        xmpProfile == .universal
            ? universalDecisionKeywords
            : xmpProfile.usesVisibleDecisionKeywordsByDefault
    }

    private var mixedMetadataNote: String {
        var parts: [String] = []
        var total = 0
        if store.mixedStarCount > 0 {
            parts.append("\(store.mixedStarCount) mixed-star pair\(store.mixedStarCount == 1 ? "" : "s")")
            total += store.mixedStarCount
        }
        if store.mixedColorCount > 0 {
            parts.append("\(store.mixedColorCount) mixed-color pair\(store.mixedColorCount == 1 ? "" : "s")")
            total += store.mixedColorCount
        }
        return parts.joined(separator: " and ")
            + (total == 1 ? " matches" : " match")
            + " only when Mixed is selected in the corresponding menu."
    }

    private var starSelectionSummary: String {
        selectionSummary(
            selectedStars,
            all: ExportSelectionPredicate.allStarStates,
            label: starStateLabel
        )
    }

    private var colorSelectionSummary: String {
        selectionSummary(
            selectedColors,
            all: ExportSelectionPredicate.allColorStates,
            label: colorStateLabel
        )
    }

    private func selectionSummary<Value: Hashable>(
        _ selected: Set<Value>,
        all: Set<Value>,
        label: (Value) -> String
    ) -> String {
        if selected == all { return "All selected" }
        if selected.isEmpty { return "None selected" }
        if selected.count == 1, let only = selected.first {
            return label(only)
        }
        return "\(selected.count) selected"
    }

    private func starStateLabel(_ state: PhotoItemStarRatingState) -> String {
        switch state {
        case .unrated: return "Unrated"
        case .stars(let rating):
            return rating == .one ? "1 star" : "\(rating.count) stars"
        case .mixed: return "Mixed"
        }
    }

    private func colorStateLabel(_ state: PhotoItemColorLabelState) -> String {
        switch state {
        case .none: return "None"
        case .label(let label): return label.displayName
        case .mixed: return "Mixed"
        }
    }

    private func membershipBinding<Value: Hashable>(
        _ value: Value,
        in selection: Binding<Set<Value>>
    ) -> Binding<Bool> {
        Binding {
            selection.wrappedValue.contains(value)
        } set: { isSelected in
            if isSelected {
                selection.wrappedValue.insert(value)
            } else {
                selection.wrappedValue.remove(value)
            }
        }
    }

    private func exportMenuRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            content()
                .labelsHidden()
                .frame(width: 170)
        }
    }

    private func ratingTile(_ rating: Rating, count: Int, label: String, color: Color) -> some View {
        let isSelected = selectedRatings.contains(rating)
        return Button {
            if isSelected {
                selectedRatings.remove(rating)
            } else {
                selectedRatings.insert(rating)
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(.title.bold())
                    .foregroundStyle(isSelected ? color : color.opacity(0.35))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .frame(minWidth: 70)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Click to leave \(label) items out" : "Click to include \(label) items")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var xmpContent: some View {
        switch store.xmpPublicationState {
        case .idle:
            summaryView
        case .preflighting(let done, let total):
            xmpProgressView(
                title: "Checking sidecars…",
                done: done,
                total: total,
                stopTitle: "Stop Checking"
            )
        case .awaitingConfirmation(let plan):
            xmpPreflightView(plan)
        case .publishing(let done, let total):
            xmpProgressView(
                title: "Writing Metadata (XMP)…",
                done: done,
                total: total,
                stopTitle: "Stop Writing"
            )
        case .cancelling:
            VStack(spacing: 12) {
                ProgressView()
                Text("Stopping at a safe boundary…")
                    .font(.headline)
                Text("An atomic sidecar replacement already in progress will finish safely first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .finished(let result):
            xmpFinishedView(result)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                Text(message)
                    .multilineTextAlignment(.center)
                Button("OK") { store.resetXMPPublication() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func xmpProgressView(
        title: String,
        done: Int,
        total: Int,
        stopTitle: String
    ) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            ProgressView(
                value: Double(done),
                total: Double(max(total, 1))
            )
            Text("\(done) of \(total) sidecar families")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(stopTitle) { store.cancelXMPPublication() }
        }
    }

    private func xmpPreflightView(_ plan: XMPPublicationPlan) -> some View {
        let issues = plan.entries.filter { !$0.category.canPublish }
        let changes = plan.changeCounts
        return VStack(spacing: 14) {
            Text("Metadata (XMP)")
                .font(.title2.bold())
            Text("Ready to write with \(plan.profile.displayName)")
                .font(.headline)

            VStack(spacing: 6) {
                xmpCountRow("Selected Louppe items", plan.selectedItemCount)
                xmpCountRow("Physical photo files", plan.physicalFileCount)
                xmpCountRow("Sidecars to create", plan.count(.create))
                xmpCountRow("Sidecars to update", plan.count(.update))
                xmpCountRow("Already current", plan.count(.alreadyCurrent))
                xmpCountRow(
                    "Existing recognized sidecars",
                    plan.entries.count(where: {
                        $0.category != .create
                            && $0.canonicalSidecar != nil
                    })
                )
                ForEach(
                    XMPPublicationCategory.allCases.filter {
                        !$0.canPublish
                            && $0 != .copyUnchangedApplicationPacket
                            && plan.count($0) > 0
                    },
                    id: \.rawValue
                ) { category in
                    xmpCountRow(category.label, plan.count(category))
                }
            }

            Text(xmpApplicationNote(plan.profile))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !plan.bestEffortFilenames.isEmpty {
                warningText("This application may ignore sidecars for JPEG, TIFF, DNG, HEIC, or PNG because it normally expects embedded metadata. Louppe will not modify the original. Affected: \(fileList(plan.bestEffortFilenames))")
            }
            if changes.stars + changes.colors + changes.flags + changes.keywords > 0 {
                warningText(
                    "Existing non-empty values will change — stars: \(changes.stars), colors: \(changes.colors), flags: \(changes.flags), reserved decision keywords: \(changes.keywords)."
                )
            }
            if plan.applicationPacketCount > 0 {
                Text("\(plan.applicationPacketCount) extension-qualified application packet\(plan.applicationPacketCount == 1 ? "" : "s") will remain unchanged beside the originals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if plan.excludedACRCompanionCount > 0 {
                warningText("\(plan.excludedACRCompanionCount) Lightroom .acr companion\(plan.excludedACRCompanionCount == 1 ? "" : "s") will remain untouched beside the originals. Louppe does not read or modify Lightroom heavy-edit data.")
            }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("These files will be skipped")
                        .font(.caption.weight(.semibold))
                    ForEach(issues.prefix(6)) { issue in
                        Text("\(issue.filenames.joined(separator: ", ")) — \(issue.category.label)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if issues.count > 6 {
                        Text("…and \(issues.count - 6) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Back") { store.resetXMPPublication() }
                    .keyboardShortcut(.cancelAction)
                Button("Write Sidecars") {
                    store.startXMPPublication(planID: plan.id)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.publishableCount == 0)
            }
        }
    }

    private func xmpFinishedView(_ result: XMPPublicationResult) -> some View {
        let hasDetails = !result.details.isEmpty
        return VStack(spacing: 14) {
            Image(systemName: result.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(result.isClean ? .green : .orange)
            Text(result.cancelled
                ? "Metadata writing stopped"
                : result.isClean
                    ? "Metadata (XMP) complete"
                    : "Metadata (XMP) finished with problems")
                .font(.title3.bold())

            VStack(spacing: 6) {
                xmpCountRow("Created", result.created)
                xmpCountRow("Updated", result.updated)
                xmpCountRow("Already current", result.alreadyCurrent)
                xmpCountRow("Skipped", result.skipped)
                xmpCountRow("Conflicts", result.conflicts)
                xmpCountRow("Failed", result.failed)
            }

            if result.cancelled {
                Text("Completed sidecars remain safely written. No partially replaced packet was left behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if showXMPDetails, hasDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.details) { detail in
                            Text("\(detail.filenames.joined(separator: ", ")) — \(detail.category.label): \(detail.message)")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            HStack {
                if hasDetails {
                    Button(showXMPDetails ? "Hide Details" : "Show Details") {
                        showXMPDetails.toggle()
                    }
                }
                Button("Done") {
                    store.resetXMPPublication()
                    store.isExportPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func xmpCountRow(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.callout)
    }

    private func warningText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
    }

    private func fileList(_ names: [String]) -> String {
        if names.count <= 4 { return names.joined(separator: ", ") }
        return names.prefix(4).joined(separator: ", ")
            + ", and \(names.count - 4) more"
    }

    private func xmpApplicationNote(_ profile: XMPApplicationProfile) -> String {
        switch profile {
        case .lightroomClassic:
            return "After publication, use Lightroom Classic’s Read Metadata from Files command so its catalog sees the sidecars."
        case .captureOne:
            return "Capture One may need XMP Auto Sync enabled or a manual metadata reload."
        case .darktable:
            return "darktable reads the portable stem sidecar on import; its processing-history packet remains unchanged."
        case .bridge:
            return "Bridge reads stars, colors, and Louppe’s visible decision keywords from the sidecars."
        case .universal:
            return "Universal XMP keeps stars, colors, and the lossless Louppe decision in portable fields."
        }
    }

    private func workingView(mode: ExportMode, done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            Text(mode == .copy ? "Copying media…" : "Moving media…")
                .font(.headline)
            ProgressView(value: Double(done), total: Double(total))
            Text("\(done) of \(total) files")
                .font(.caption)
                .foregroundStyle(.secondary)
            if mode == .copy {
                Button(exporter.isCancellingCopy ? "Stopping…" : "Stop Copying") {
                    exporter.cancelCopy()
                }
                .disabled(exporter.isCancellingCopy)
            }
        }
    }

    private func xmpExportPreparationView(mode: ExportMode) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking XMP sidecars…")
                .font(.headline)
            Text("Louppe is preparing one immutable, recoverable \(mode == .copy ? "copy" : "move") plan before any file changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Stop Checking") {
                exporter.cancelXMPPreparation()
            }
        }
    }

    private func xmpExportPreflightView(
        _ confirmation: ExportManager.XMPConfirmation
    ) -> some View {
        let plan = confirmation.plan
        let changes = plan.changeCounts
        return VStack(spacing: 14) {
            Text(confirmation.mode == .copy ? "Copy with XMP" : "Move with XMP")
                .font(.title2.bold())
            Text("Ready for \(confirmation.destination.lastPathComponent)")
                .font(.headline)

            VStack(spacing: 6) {
                xmpCountRow("Selected Louppe items", plan.selectedItemCount)
                xmpCountRow("Physical media files", plan.physicalFileCount)
                xmpCountRow(
                    "Existing recognized sidecars",
                    plan.existingRecognizedPacketCount
                )
                xmpCountRow("Sidecars to create", plan.count(.create))
                xmpCountRow("Sidecars to update", plan.count(.update))
                xmpCountRow(
                    "Already current",
                    plan.count(.alreadyCurrent)
                )
                if plan.applicationPacketCount > 0 {
                    xmpCountRow(
                        "Application packets copied unchanged",
                        plan.applicationPacketCount
                    )
                }
                ForEach(
                    XMPPublicationCategory.allCases.filter {
                        !$0.canPublish
                            && $0 != .copyUnchangedApplicationPacket
                            && plan.count($0) > 0
                    },
                    id: \.rawValue
                ) { category in
                    xmpCountRow(category.label, plan.count(category))
                }
                if plan.excludedACRCompanionCount > 0 {
                    xmpCountRow(
                        "Lightroom .acr companions excluded",
                        plan.excludedACRCompanionCount
                    )
                }
            }

            if changes.stars + changes.colors + changes.flags
                + changes.keywords > 0 {
                Text("Existing values to update: \(changes.stars) star, \(changes.colors) color, \(changes.flags) decision flag, \(changes.keywords) keyword set.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if !plan.bestEffortFilenames.isEmpty {
                Text("Some applications may ignore sidecars for: \(plan.bestEffortFilenames.joined(separator: ", ")). Original media will not be modified.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if !plan.issueFamilies.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.issueFamilies, id: \.id) { family in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(family.filenames.joined(separator: ", "))
                                    .font(.caption.weight(.semibold))
                                Text(family.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            Text("Media and every included sidecar will enter one recovery plan before the first file changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Back") { exporter.backFromXMPConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.mode == .copy ? "Start Copy" : "Start Move") {
                    exporter.confirmXMPExport()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finishedView(outcome: ExportManager.Outcome) -> some View {
        VStack(spacing: 14) {
            Image(systemName: outcome.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(outcome.isClean ? .green : .orange)
            Text(finishedTitle(for: outcome))
                .font(.title3.bold())
            Text(finishedMessage(for: outcome))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let xmp = outcome.xmpSummary {
                VStack(spacing: 6) {
                    xmpCountRow("Media \(outcome.mode == .copy ? "copied" : "moved")", xmp.mediaFiles)
                    xmpCountRow("Sidecars created", xmp.created)
                    xmpCountRow("Sidecars updated", xmp.updated)
                    xmpCountRow("Sidecars already current", xmp.alreadyCurrent)
                    xmpCountRow(
                        "Application packets copied unchanged",
                        xmp.copiedUnchanged
                    )
                    if xmp.unsupported > 0 {
                        xmpCountRow("Unsupported media", xmp.unsupported)
                    }
                    if xmp.skipped > 0 {
                        xmpCountRow("Skipped", xmp.skipped)
                    }
                    if xmp.conflicts > 0 {
                        xmpCountRow("Conflicts", xmp.conflicts)
                    }
                    if xmp.failed > 0 {
                        xmpCountRow("XMP failures", xmp.failed)
                    }
                }
            }
            HStack {
                Button("Show in Finder") {
                    exporter.revealInFinder(outcome.destination)
                }
                Button("Done") {
                    store.isExportPresented = false
                    exporter.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finishedTitle(for outcome: ExportManager.Outcome) -> String {
        if outcome.recoveryRequired {
            return outcome.mode == .copy
                ? "Securing copied files"
                : "Restoring files for safety"
        }
        if outcome.cancelled { return "Copy stopped" }
        return outcome.isClean ? "Export complete" : "Export finished with problems"
    }

    private func finishedMessage(for outcome: ExportManager.Outcome) -> String {
        if outcome.recoveryRequired {
            let cause = outcome.failureMessage.map {
                $0.hasSuffix(".") ? "\($0) " : "\($0). "
            } ?? ""
            if outcome.mode == .copy {
                return cause
                    + "Louppe kept a durable record of the interrupted copy and is preserving every verified completed file while checking the unfinished transfer. Wait for the recovery notice before starting another file operation."
            }
            return cause
                + "Louppe kept a durable record of the interrupted move and is returning every affected original to its safe source state. Wait for the recovery notice before starting another file operation."
        }
        let verb = outcome.mode == .copy ? "copied" : "moved"
        var text = "\(outcome.files) file\(outcome.files == 1 ? "" : "s") \(verb) to \(outcome.destination.lastPathComponent)"
        switch outcome.mode {
        case .copy:
            if outcome.cancelled {
                text += ". Completed photos remain at the destination; the photo in progress was rolled back."
            } else if outcome.failedPhotos > 0 {
                let agreement = outcome.failedPhotos == 1 ? "was" : "were"
                text += " — \(outcome.failedPhotos) item\(outcome.failedPhotos == 1 ? "" : "s") couldn't be copied and \(agreement) rolled back."
            } else {
                text += "."
            }
            if outcome.inconsistentPhotos > 0 {
                text += " For \(outcome.inconsistentPhotos), rollback also failed; check the destination for a partial pair."
            }
        case .move:
            if outcome.failedPhotos > 0 {
                text += " — \(outcome.failedPhotos) item\(outcome.failedPhotos == 1 ? "" : "s") couldn't be moved and stayed in the session."
            } else {
                text += "."
            }
            if outcome.inconsistentPhotos > 0 {
                text += " For \(outcome.inconsistentPhotos), rollback also failed; check both the source folder and the destination."
            }
        case .metadataXMP:
            break
        }
        if outcome.journalFailure {
            text += " Louppe's file-safety checks stopped the operation before another file was started; affected originals remain at their last verified location."
        }
        if let failure = outcome.failureMessage {
            text += failure.hasSuffix(".") ? " \(failure)" : " \(failure)."
        }
        return text
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
            Button("OK") {
                exporter.reset()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
