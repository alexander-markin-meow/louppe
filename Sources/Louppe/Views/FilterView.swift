import SwiftUI

/// The toolbar filter popover. Metadata is cached during scanning, so every
/// control below only filters in-memory `PhotoItem` values.
struct FilterView: View {
    @ObservedObject var store: SessionStore

    @State private var dateExpanded = true
    @State private var cameraSettingsExpanded = false
    @State private var subfoldersExpanded = true
    @State private var fileTypesExpanded = true
    @State private var camerasExpanded = false
    @State private var lensesExpanded = false

    @State private var apertureFromText = ""
    @State private var apertureToText = ""
    @State private var shutterFromText = ""
    @State private var shutterToText = ""
    @State private var isoFromText = ""
    @State private var isoToText = ""
    @State private var settingCommitTask: Task<Void, Never>?
    @FocusState private var focusedSettingField: SettingField?

    private enum SettingField: Hashable {
        case apertureFrom, apertureTo
        case shutterFrom, shutterTo
        case isoFrom, isoTo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    dateSection

                    if store.availableSubfolders.count > 1 {
                        Divider()
                        subfoldersSection
                    }

                    Divider()
                    fileTypesSection

                    if store.availableCameras.count > 1 {
                        Divider()
                        camerasSection
                    }

                    if store.availableLenses.count > 1 {
                        Divider()
                        lensesSection
                    }

                    if store.apertureRange != nil || store.shutterRange != nil || store.isoRange != nil {
                        Divider()
                        cameraSettingsSection
                    }
                }
                .padding(.trailing, 5)
            }

            Divider()
            footer
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 340, height: 560)
        .onAppear { syncAllSettingDrafts() }
        .onDisappear {
            settingCommitTask?.cancel()
            settingCommitTask = nil
            commitAllSettingDrafts()
        }
        .onChange(of: focusedSettingField) { previous, current in
            if let previous, previous != current {
                restoreInvalidDraft(for: previous)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search name, camera, lens…", text: $store.filter.searchText)
                .textFieldStyle(.plain)
            if !store.filter.searchText.isEmpty {
                Button {
                    store.filter.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Date

    private var dateSection: some View {
        FilterDisclosureSection(title: "Date taken", isExpanded: $dateExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                Picker("Date filter", selection: dateModeBinding) {
                    Text("Range").tag(DateFilterMode.range)
                    Text("Specific dates").tag(DateFilterMode.specificDates)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if store.filter.dateMode == .range {
                    if store.captureDateRange != nil {
                        DatePicker(
                            "From",
                            selection: dateFromBinding,
                            in: dateFromLimits,
                            displayedComponents: .date
                        )
                        DatePicker(
                            "To",
                            selection: dateToBinding,
                            in: dateToLimits,
                            displayedComponents: .date
                        )
                    } else {
                        Text("This folder contains no dated photos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Button("Select all", action: selectAllDates)
                            Button("Clear", action: clearAllDates)
                            Spacer()
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)

                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(store.availableCaptureDates, id: \.self) { date in
                                Toggle(isOn: dateBinding(date)) {
                                    labeledCount(
                                        Self.dayFormatter.string(from: date),
                                        store.captureDateCounts[date, default: 0]
                                    )
                                }
                            }

                            if store.unknownDateCount > 0 {
                                Toggle(isOn: unknownDateBinding) {
                                    labeledCount("Unknown date", store.unknownDateCount)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Camera settings

    private var cameraSettingsSection: some View {
        FilterDisclosureSection(title: "Camera settings", isExpanded: $cameraSettingsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if store.apertureRange != nil { apertureSetting }
                if store.shutterRange != nil { shutterSetting }
                if store.isoRange != nil { isoSetting }
            }
        }
    }

    private var apertureSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Aperture")
            HStack(spacing: 5) {
                Text("From")
                Text("f/").foregroundStyle(.secondary)
                validatedTextField($apertureFromText, field: .apertureFrom, width: 52, invalid: !apertureDraftIsValid)
                Text("to").foregroundStyle(.secondary)
                Text("f/").foregroundStyle(.secondary)
                validatedTextField($apertureToText, field: .apertureTo, width: 52, invalid: !apertureDraftIsValid)
            }
            .padding(.leading, 20)
            if !apertureDraftIsValid { invalidRangeMessage }
        }
        .onChange(of: apertureFromText) { scheduleSettingCommit() }
        .onChange(of: apertureToText) { scheduleSettingCommit() }
    }

    private var shutterSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shutter speed")
            HStack(spacing: 5) {
                Text("From")
                validatedTextField($shutterFromText, field: .shutterFrom, width: 72, invalid: !shutterDraftIsValid)
                Text("to").foregroundStyle(.secondary)
                validatedTextField($shutterToText, field: .shutterTo, width: 72, invalid: !shutterDraftIsValid)
            }
            .padding(.leading, 20)
            if !shutterDraftIsValid { invalidRangeMessage }
        }
        .onChange(of: shutterFromText) { scheduleSettingCommit() }
        .onChange(of: shutterToText) { scheduleSettingCommit() }
    }

    private var isoSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ISO")
            HStack(spacing: 5) {
                Text("From")
                validatedTextField($isoFromText, field: .isoFrom, width: 68, invalid: !isoDraftIsValid)
                Text("to").foregroundStyle(.secondary)
                validatedTextField($isoToText, field: .isoTo, width: 68, invalid: !isoDraftIsValid)
            }
            .padding(.leading, 20)
            if !isoDraftIsValid { invalidRangeMessage }
        }
        .onChange(of: isoFromText) { scheduleSettingCommit() }
        .onChange(of: isoToText) { scheduleSettingCommit() }
    }

    private var invalidRangeMessage: some View {
        Label("Enter a valid range", systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.leading, 20)
    }

    private func validatedTextField(
        _ text: Binding<String>,
        field: SettingField,
        width: CGFloat,
        invalid: Bool
    ) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focusedSettingField, equals: field)
            .frame(width: width)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(invalid ? Color.red : Color.clear, lineWidth: 1)
            }
    }

    // MARK: - Facet sections

    private var subfoldersSection: some View {
        FilterDisclosureSection(title: "Subfolders", isExpanded: $subfoldersExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableSubfolders, id: \.self) { subfolder in
                    Toggle(isOn: exclusionBinding(subfolder, \.excludedSubfolders)) {
                        labeledCount(subfolder, store.subfolderCounts[subfolder, default: 0])
                    }
                }
            }
        }
    }

    private var fileTypesSection: some View {
        FilterDisclosureSection(title: "File types", isExpanded: $fileTypesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableTypes, id: \.self) { type in
                    Toggle(isOn: exclusionBinding(type, \.excludedTypes)) {
                        labeledCount(type, store.typeCounts[type, default: 0])
                    }
                }
            }
        }
    }

    private var camerasSection: some View {
        FilterDisclosureSection(title: "Camera", isExpanded: $camerasExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableCameras, id: \.self) { camera in
                    Toggle(isOn: exclusionBinding(camera, \.excludedCameras)) {
                        labeledCount(camera, store.cameraCounts[camera, default: 0])
                    }
                }
            }
        }
    }

    private var lensesSection: some View {
        FilterDisclosureSection(title: "Lens", isExpanded: $lensesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableLenses, id: \.self) { lens in
                    Toggle(isOn: exclusionBinding(lens, \.excludedLenses)) {
                        labeledCount(lens, store.lensCounts[lens, default: 0])
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Showing \(store.visibleIndices.count) of \(store.items.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Reset") {
                focusedSettingField = nil
                store.resetFilter()
                syncAllSettingDrafts()
            }
            .disabled(!store.filterCanReset)
        }
    }

    // MARK: - Filter bindings

    private var dateModeBinding: Binding<DateFilterMode> {
        Binding {
            store.filter.dateMode
        } set: { mode in
            var filter = store.filter
            filter.dateMode = mode
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private var dateFromBinding: Binding<Date> {
        Binding {
            store.filter.dateFrom
        } set: { date in
            var filter = store.filter
            filter.dateFrom = date
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private var dateToBinding: Binding<Date> {
        Binding {
            store.filter.dateTo
        } set: { date in
            var filter = store.filter
            filter.dateTo = date
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private var dateFromLimits: ClosedRange<Date> {
        guard let available = store.captureDateRange else {
            return store.filter.dateFrom...store.filter.dateFrom
        }
        let upper = min(max(store.filter.dateTo, available.lowerBound), available.upperBound)
        return available.lowerBound...upper
    }

    private var dateToLimits: ClosedRange<Date> {
        guard let available = store.captureDateRange else {
            return store.filter.dateTo...store.filter.dateTo
        }
        let lower = max(min(store.filter.dateFrom, available.upperBound), available.lowerBound)
        return lower...available.upperBound
    }

    private func dateBinding(_ date: Date) -> Binding<Bool> {
        Binding {
            !store.filter.excludedDates.contains(date)
        } set: { isIncluded in
            var filter = store.filter
            if isIncluded {
                filter.excludedDates.remove(date)
            } else {
                filter.excludedDates.insert(date)
            }
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private var unknownDateBinding: Binding<Bool> {
        Binding {
            !store.filter.excludesUnknownDate
        } set: { isIncluded in
            var filter = store.filter
            filter.excludesUnknownDate = !isIncluded
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private func selectAllDates() {
        var filter = store.filter
        filter.excludedDates = []
        filter.excludesUnknownDate = false
        updateDateActivation(&filter)
        store.filter = filter
    }

    private func clearAllDates() {
        var filter = store.filter
        filter.excludedDates = Set(store.availableCaptureDates)
        filter.excludesUnknownDate = true
        updateDateActivation(&filter)
        store.filter = filter
    }

    private func updateDateActivation(_ filter: inout PhotoFilter) {
        switch filter.dateMode {
        case .range:
            guard let available = store.captureDateRange else {
                filter.dateEnabled = false
                return
            }
            filter.dateEnabled = filter.dateFrom != available.lowerBound
                || filter.dateTo != available.upperBound
        case .specificDates:
            filter.dateEnabled = !filter.excludedDates.isEmpty
                || (store.unknownDateCount > 0 && filter.excludesUnknownDate)
        }
    }

    private func exclusionBinding(
        _ label: String,
        _ set: WritableKeyPath<PhotoFilter, Set<String>>
    ) -> Binding<Bool> {
        Binding {
            !store.filter[keyPath: set].contains(label)
        } set: { on in
            if on {
                store.filter[keyPath: set].remove(label)
            } else {
                store.filter[keyPath: set].insert(label)
            }
        }
    }

    // MARK: - Range drafts

    private var apertureDraftIsValid: Bool {
        guard let from = Self.parseAperture(apertureFromText),
              let to = Self.parseAperture(apertureToText) else { return false }
        return from <= to
    }

    private var shutterDraftIsValid: Bool {
        guard let from = Self.parseShutter(shutterFromText),
              let to = Self.parseShutter(shutterToText) else { return false }
        return from <= to
    }

    private var isoDraftIsValid: Bool {
        guard let from = Self.parseISO(isoFromText),
              let to = Self.parseISO(isoToText) else { return false }
        return from <= to
    }

    private func commitApertureDrafts(to filter: inout PhotoFilter) {
        guard let available = store.apertureRange,
              let parsedFrom = Self.parseAperture(apertureFromText),
              let parsedTo = Self.parseAperture(apertureToText),
              parsedFrom <= parsedTo else { return }
        let from = Self.snapAperture(parsedFrom, toDisplayedBound: available.lowerBound)
        let to = Self.snapAperture(parsedTo, toDisplayedBound: available.upperBound)
        filter.apertureFrom = from
        filter.apertureTo = to
        filter.apertureEnabled = from != available.lowerBound || to != available.upperBound
    }

    private func commitShutterDrafts(to filter: inout PhotoFilter) {
        guard let available = store.shutterRange,
              let parsedFrom = Self.parseShutter(shutterFromText),
              let parsedTo = Self.parseShutter(shutterToText),
              parsedFrom <= parsedTo else { return }
        let from = Self.snapShutter(parsedFrom, toDisplayedBound: available.lowerBound)
        let to = Self.snapShutter(parsedTo, toDisplayedBound: available.upperBound)
        filter.shutterFrom = from
        filter.shutterTo = to
        filter.shutterEnabled = from != available.lowerBound || to != available.upperBound
    }

    private func commitISODrafts(to filter: inout PhotoFilter) {
        guard let available = store.isoRange,
              let parsedFrom = Self.parseISO(isoFromText),
              let parsedTo = Self.parseISO(isoToText),
              parsedFrom <= parsedTo else { return }
        let from = Self.snapISO(parsedFrom, toDisplayedBound: available.lowerBound)
        let to = Self.snapISO(parsedTo, toDisplayedBound: available.upperBound)
        filter.isoFrom = from
        filter.isoTo = to
        filter.isoEnabled = from != available.lowerBound || to != available.upperBound
    }

    private func syncAllSettingDrafts() {
        if let range = store.apertureRange {
            let from = store.filter.apertureFrom > 0 ? store.filter.apertureFrom : range.lowerBound
            let to = store.filter.apertureTo > 0 ? store.filter.apertureTo : range.upperBound
            apertureFromText = Self.formatDecimal(from)
            apertureToText = Self.formatDecimal(to)
        }
        if let range = store.shutterRange {
            let from = store.filter.shutterFrom > 0 ? store.filter.shutterFrom : range.lowerBound
            let to = store.filter.shutterTo > 0 ? store.filter.shutterTo : range.upperBound
            shutterFromText = Self.formatShutter(from)
            shutterToText = Self.formatShutter(to)
        }
        if let range = store.isoRange {
            let from = store.filter.isoFrom > 0 ? store.filter.isoFrom : range.lowerBound
            let to = store.filter.isoTo > 0 ? store.filter.isoTo : range.upperBound
            isoFromText = Self.formatISO(from)
            isoToText = Self.formatISO(to)
        }
    }

    /// Numeric text can be valid on every keystroke ("3", "32", "320"),
    /// but each assignment walks the full photo list. Coalesce continuous
    /// typing just like metadata search while preserving responsive results.
    private func scheduleSettingCommit() {
        settingCommitTask?.cancel()
        settingCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            commitAllSettingDrafts()
            settingCommitTask = nil
        }
    }

    private func commitAllSettingDrafts() {
        var updated = store.filter
        commitApertureDrafts(to: &updated)
        commitShutterDrafts(to: &updated)
        commitISODrafts(to: &updated)
        if updated != store.filter {
            // One assignment means one pass across the photo list even if
            // several camera-setting fields changed before the debounce fired.
            store.filter = updated
        }
    }

    private func restoreInvalidDraft(for field: SettingField) {
        switch field {
        case .apertureFrom where !apertureDraftIsValid:
            apertureFromText = Self.formatDecimal(store.filter.apertureFrom)
        case .apertureTo where !apertureDraftIsValid:
            apertureToText = Self.formatDecimal(store.filter.apertureTo)
        case .shutterFrom where !shutterDraftIsValid:
            shutterFromText = Self.formatShutter(store.filter.shutterFrom)
        case .shutterTo where !shutterDraftIsValid:
            shutterToText = Self.formatShutter(store.filter.shutterTo)
        case .isoFrom where !isoDraftIsValid:
            isoFromText = Self.formatISO(store.filter.isoFrom)
        case .isoTo where !isoDraftIsValid:
            isoToText = Self.formatISO(store.filter.isoTo)
        default:
            break
        }
    }

    // MARK: - Formatting

    private static func parseAperture(_ text: String) -> Double? {
        var value = normalizedNumberText(text).lowercased()
        if value.hasPrefix("f/") { value.removeFirst(2) }
        guard let number = Double(value), number.isFinite, number > 0 else { return nil }
        return number
    }

    private static func parseShutter(_ text: String) -> Double? {
        var value = normalizedNumberText(text).lowercased()
        if value.hasSuffix("s") { value.removeLast() }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        let seconds: Double?
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            seconds = numerator / denominator
        } else if components.count == 1 {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static func parseISO(_ text: String) -> Double? {
        guard let number = Double(normalizedNumberText(text)),
              number.isFinite,
              number > 0,
              number.rounded() == number else { return nil }
        return number
    }

    private static func normalizedNumberText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
    }

    private static func formatDecimal(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "" }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func formatShutter(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds >= 1 {
            return "\(formatDecimal(seconds))s"
        }
        let denominator = (1 / seconds).rounded()
        if denominator >= 1, abs(seconds - (1 / denominator)) < 0.000_001 {
            return "1/\(Int(denominator))"
        }
        return "\(formatDecimal(seconds))s"
    }

    private static func formatISO(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "" }
        return String(format: "%.0f", value)
    }

    /// Display formatting rounds some legal EXIF values. If the user-entered
    /// value equals what a folder bound displays, retain the exact bound so a
    /// neutral full range cannot accidentally exclude its edge photo.
    private static func snapAperture(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseAperture(formatDecimal(bound)) == value ? bound : value
    }

    private static func snapShutter(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseShutter(formatShutter(bound)) == value ? bound : value
    }

    private static func snapISO(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseISO(formatISO(bound)) == value ? bound : value
    }

    private func labeledCount(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// A native-looking disclosure row whose whole width, including its title, is
/// clickable. SwiftUI's standard DisclosureGroup gives the chevron a much more
/// obvious hit target than the label on macOS, which made the title feel inert.
private struct FilterDisclosureSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    private let content: Content

    init(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                        .frame(width: 12)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
