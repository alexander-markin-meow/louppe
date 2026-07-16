import Foundation
import AppKit

enum ViewMode {
    case gallery
    case grid
}

enum AppPhase {
    case welcome
    case scanning(found: Int)
    case ready
}

enum ZoomMode {
    case fit      // fill the pane
    case actual   // 100%, scrollable
    case small    // phone-sized preview
}

/// The app's single source of truth: the loaded session (photos + ratings),
/// navigation, undo, view state, and persistence to the sidecar file.
@MainActor
final class SessionStore: ObservableObject {
    @Published var phase: AppPhase = .welcome
    @Published var items: [PhotoItem] = []
    @Published var currentIndex: Int = 0
    @Published var viewMode: ViewMode = .gallery
    @Published var showMetadataPanel = true
    @Published var showBrowser = true
    @Published var zoomMode: ZoomMode = .fit
    @Published var gridThumbSize: CGFloat = 170
    /// Number of adaptive columns currently visible in the Grid view.
    /// GridView updates this from the actual available window width.
    // Navigation reads this value, but no view renders it. Publishing it would
    // force a redundant second grid redraw after every resize/thumbnail zoom.
    private(set) var gridColumnCount = 1
    @Published var isExportPresented = false
    @Published var isFilterPresented = false
    /// In-flight big-photo decodes (a count, so overlapping loads during fast
    /// arrow-key navigation can't blank the spinner early). The toolbar shows
    /// a small spinner while it's above zero.
    @Published var fullImageLoads = 0
    @Published var scanError: String?
    @Published var recentFolders: [URL] = []

    /// The toolbar filter. Views only render `visibleIndices`; `items` stays
    /// the full list so ratings and the sidecar are never affected by filtering.
    @Published var filter = PhotoFilter() {
        didSet {
            guard filter != oldValue else { return }
            var newNonSearch = filter
            var oldNonSearch = oldValue
            newNonSearch.searchText = ""
            oldNonSearch.searchText = ""
            if newNonSearch == oldNonSearch {
                scheduleSearchFilter()
            } else {
                filterDebounce?.cancel()
                filterDebounce = nil
                applyFilter()
            }
        }
    }
    /// The toolbar sort menu. Reorders `visibleIndices` only — `items` keeps
    /// its scan order, so undo indices and the sidecar are unaffected.
    @Published var sort = PhotoSort() {
        didSet {
            if sort != oldValue {
                filterDebounce?.cancel()
                filterDebounce = nil
                rebuildSortedIndices()
                applyFilter()
            }
        }
    }
    /// Indices into `items` that pass the current filter, in the chosen sort order.
    @Published private(set) var visibleIndices: [Int] = []
    /// Same visible order, split into day runs for the Grid view. Rebuilt
    /// only when filter/sort/session structure changes, not on selection drag.
    @Published private(set) var visibleDayGroups: [[Int]] = []
    @Published private(set) var visibleDayStartIndices: Set<Int> = []

    /// The multi-selection (absolute indices into `items`). Empty is the
    /// normal single-photo state: the selection is just `currentIndex`.
    /// Selection gestures keep `currentIndex` inside the set as the anchor.
    @Published private(set) var selectedIndices: Set<Int> = []

    private(set) var sourceFolder: URL?

    /// One undo step can hold several photo changes (e.g. "clear all"),
    /// so a single ⌘Z restores the whole batch.
    private struct RatingChange {
        let index: Int
        let previousRating: Rating
        let previousRatedAt: Date?
    }
    /// A photo removed by Clean Up, with everything needed to bring it back:
    /// its former position in `items` and where each file landed in the Trash.
    private struct RemovedPhoto: Sendable {
        let index: Int
        let item: PhotoItem
        let trashedFiles: [TrashedFile]
    }
    private enum UndoStep {
        case ratings([RatingChange], previousIndex: Int)
        case cleanUp([RemovedPhoto], previousIndex: Int)
    }
    private var undoStack: [UndoStep] = []
    private var saveDebounce: DispatchWorkItem?
    private var pendingPersistenceTask: Task<Void, Never>?
    private var filterDebounce: DispatchWorkItem?
    private var prefetchDebounce: DispatchWorkItem?
    private var scanTask: Task<Void, Never>?
    private let persistence = SessionPersistence()
    private var saveSequence: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var cleanUpGeneration: UInt64 = 0
    private var sortedIndices: [Int] = []
    private var ratingTally = (yes: 0, no: 0, undecided: 0)

    @Published private(set) var availableTypes: [String] = []
    @Published private(set) var availableCameras: [String] = []
    @Published private(set) var availableLenses: [String] = []
    @Published private(set) var availableSubfolders: [String] = []
    @Published private(set) var availableCaptureDates: [Date] = []
    @Published private(set) var captureDateRange: ClosedRange<Date>?
    @Published private(set) var apertureRange: ClosedRange<Double>?
    @Published private(set) var shutterRange: ClosedRange<Double>?
    @Published private(set) var isoRange: ClosedRange<Double>?
    @Published private(set) var typeCounts: [String: Int] = [:]
    @Published private(set) var cameraCounts: [String: Int] = [:]
    @Published private(set) var lensCounts: [String: Int] = [:]
    @Published private(set) var subfolderCounts: [String: Int] = [:]
    @Published private(set) var captureDateCounts: [Date: Int] = [:]
    @Published private(set) var unknownDateCount = 0

    nonisolated static let sidecarName = SessionConstants.sidecarName

    init() {
        loadRecents()
    }

    // MARK: - Counts

    var yesCount: Int { ratingTally.yes }
    var noCount: Int { ratingTally.no }
    var undecidedCount: Int { ratingTally.undecided }
    var ratedCount: Int { ratingTally.yes + ratingTally.no }

    /// Reset remains available when the date UI is in its non-default mode or
    /// retains hidden day exclusions, even if those choices currently show all
    /// photos and therefore do not light the toolbar's active-filter glyph.
    var filterCanReset: Bool {
        filter.isActive
            || filter.dateMode != .range
            || !filter.excludedDates.isEmpty
            || filter.excludesUnknownDate
    }

    var currentItem: PhotoItem? {
        // When a filter matches nothing there is deliberately no current
        // photo; returning the previously current hidden item would expose it
        // in the Info panel and make keyboard actions target it invisibly.
        guard !visibleIndices.isEmpty, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    // MARK: - Filtering

    private func applyFilter() {
        let prepared = PreparedPhotoFilter(filter)
        visibleIndices = sortedIndices.filter { prepared.matches(items[$0]) }
        visibleDayGroups = makeVisibleDayGroups()
        visibleDayStartIndices = Set(visibleDayGroups.dropFirst().compactMap(\.first))
        // Photos that just got filtered out must leave the selection too —
        // an invisible photo shouldn't silently receive a rating.
        if !selectedIndices.isEmpty {
            selectedIndices.formIntersection(visibleIndices)
        }
        // Keep the current photo visible: snap to the nearest photo that
        // passes the filter (forward first, else the last visible one).
        if !visibleIndices.isEmpty, !visibleIndices.contains(currentIndex) {
            currentIndex = visibleIndices.first(where: { $0 >= currentIndex }) ?? visibleIndices.last!
        }
        prefetchAroundCurrent()
    }

    private func scheduleSearchFilter() {
        filterDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.filterDebounce = nil
            self.applyFilter()
        }
        filterDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Destructive actions must use the filter text currently on screen, not
    /// the results from up to 150 ms ago while search typing is debounced.
    private func flushPendingFilter() {
        guard filterDebounce != nil else { return }
        filterDebounce?.cancel()
        filterDebounce = nil
        applyFilter()
    }

    private func rebuildSortedIndices() {
        sortedIndices = items.indices.sorted { sort.areInOrder(items[$0], items[$1]) }
    }

    private func makeVisibleDayGroups() -> [[Int]] {
        guard !visibleIndices.isEmpty else { return [] }
        guard sort.key == .captureDate else { return [visibleIndices] }
        let calendar = Calendar.current
        var groups: [[Int]] = []
        var previousDate: Date?
        for index in visibleIndices {
            let date = items[index].captureDate
            let startsGroup: Bool
            if groups.isEmpty {
                startsGroup = true
            } else if let previousDate, let date {
                startsGroup = !calendar.isDate(previousDate, inSameDayAs: date)
            } else {
                startsGroup = previousDate != nil || date != nil
            }
            if startsGroup { groups.append([]) }
            groups[groups.count - 1].append(index)
            previousDate = date
        }
        return groups
    }

    /// Rebuild all values derived from session structure in one pass. Ratings
    /// use incremental updates during normal culling; structural operations are
    /// rare enough that a single complete rebuild is clearer and safer.
    private func rebuildDerivedData() {
        var tally = (yes: 0, no: 0, undecided: 0)
        var types: [String: Int] = [:]
        var cameras: [String: Int] = [:]
        var lenses: [String: Int] = [:]
        var subfolders: [String: Int] = [:]
        var dates: [Date: Int] = [:]
        var unknownDates = 0
        var minimumAperture: Double?
        var maximumAperture: Double?
        var minimumShutter: Double?
        var maximumShutter: Double?
        var minimumISO: Double?
        var maximumISO: Double?
        for item in items {
            switch item.rating {
            case .yes: tally.yes += 1
            case .no: tally.no += 1
            case .undecided: tally.undecided += 1
            }
            types[item.fileTypeLabel, default: 0] += 1
            cameras[item.cameraLabel, default: 0] += 1
            lenses[item.lensLabel, default: 0] += 1
            subfolders[item.subfolderLabel, default: 0] += 1
            if let day = item.captureDay {
                dates[day, default: 0] += 1
            } else {
                unknownDates += 1
            }
            if let aperture = item.aperture {
                minimumAperture = minimumAperture.map { min($0, aperture) } ?? aperture
                maximumAperture = maximumAperture.map { max($0, aperture) } ?? aperture
            }
            if let shutter = item.shutterSpeed {
                minimumShutter = minimumShutter.map { min($0, shutter) } ?? shutter
                maximumShutter = maximumShutter.map { max($0, shutter) } ?? shutter
            }
            if let iso = item.iso {
                minimumISO = minimumISO.map { min($0, iso) } ?? iso
                maximumISO = maximumISO.map { max($0, iso) } ?? iso
            }
        }
        ratingTally = tally
        typeCounts = types
        cameraCounts = cameras
        lensCounts = lenses
        subfolderCounts = subfolders
        availableTypes = types.keys.sorted()
        availableCameras = cameras.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        availableLenses = lenses.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // "None" (the folder root) always lists last, like the date list's
        // "Unknown date" entry.
        var subfolderLabels = subfolders.keys
            .filter { $0 != "None" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if subfolders["None"] != nil { subfolderLabels.append("None") }
        availableSubfolders = subfolderLabels
        availableCaptureDates = dates.keys.sorted()
        captureDateCounts = dates
        unknownDateCount = unknownDates
        captureDateRange = availableCaptureDates.first.flatMap { first in
            availableCaptureDates.last.map { first...$0 }
        }
        apertureRange = Self.closedRange(minimum: minimumAperture, maximum: maximumAperture)
        shutterRange = Self.closedRange(minimum: minimumShutter, maximum: maximumShutter)
        isoRange = Self.closedRange(minimum: minimumISO, maximum: maximumISO)
        rebuildSortedIndices()
    }

    private static func closedRange(minimum: Double?, maximum: Double?) -> ClosedRange<Double>? {
        guard let minimum, let maximum else { return nil }
        return minimum...maximum
    }

    /// Folder-wide ranges are the neutral filter state. Existing narrowed
    /// ranges survive a re-scan and are clamped to the newly discovered span;
    /// untouched ranges expand to the new full span automatically.
    /// Returns true when assigning the synchronized filter already caused its
    /// `didSet` observer to run `applyFilter()`.
    @discardableResult
    private func synchronizeFilterRangesWithAvailableData() -> Bool {
        var updated = filter
        updated.excludedTypes.formIntersection(availableTypes)
        updated.excludedCameras.formIntersection(availableCameras)
        updated.excludedLenses.formIntersection(availableLenses)
        updated.excludedSubfolders.formIntersection(availableSubfolders)
        updated.excludedDates.formIntersection(availableCaptureDates)

        if let available = captureDateRange {
            if updated.dateMode == .range, updated.dateEnabled {
                updated.dateFrom = Self.clamp(updated.dateFrom, to: available)
                updated.dateTo = Self.clamp(updated.dateTo, to: available)
            } else {
                updated.dateFrom = available.lowerBound
                updated.dateTo = available.upperBound
            }
        }
        updated.dateEnabled = dateFilterHasEffect(updated)

        let aperture = Self.synchronizedNumericRange(
            from: updated.apertureFrom,
            to: updated.apertureTo,
            wasActive: updated.apertureEnabled,
            available: apertureRange
        )
        updated.apertureFrom = aperture.from
        updated.apertureTo = aperture.to
        updated.apertureEnabled = aperture.isActive

        let shutter = Self.synchronizedNumericRange(
            from: updated.shutterFrom,
            to: updated.shutterTo,
            wasActive: updated.shutterEnabled,
            available: shutterRange
        )
        updated.shutterFrom = shutter.from
        updated.shutterTo = shutter.to
        updated.shutterEnabled = shutter.isActive

        let iso = Self.synchronizedNumericRange(
            from: updated.isoFrom,
            to: updated.isoTo,
            wasActive: updated.isoEnabled,
            available: isoRange
        )
        updated.isoFrom = iso.from
        updated.isoTo = iso.to
        updated.isoEnabled = iso.isActive

        guard updated != filter else { return false }
        filter = updated
        return true
    }

    /// Restores the visible controls to their folder-wide defaults. This is
    /// deliberately different from a bare `PhotoFilter()` because DatePicker
    /// selections must already lie inside the current folder's limits.
    func resetFilter() {
        var reset = PhotoFilter()
        if let available = captureDateRange {
            reset.dateFrom = available.lowerBound
            reset.dateTo = available.upperBound
        }
        if let available = apertureRange {
            reset.apertureFrom = available.lowerBound
            reset.apertureTo = available.upperBound
        }
        if let available = shutterRange {
            reset.shutterFrom = available.lowerBound
            reset.shutterTo = available.upperBound
        }
        if let available = isoRange {
            reset.isoFrom = available.lowerBound
            reset.isoTo = available.upperBound
        }
        filter = reset
    }

    private func dateFilterHasEffect(_ candidate: PhotoFilter) -> Bool {
        switch candidate.dateMode {
        case .range:
            guard let available = captureDateRange else { return false }
            return candidate.dateFrom != available.lowerBound || candidate.dateTo != available.upperBound
        case .specificDates:
            return !candidate.excludedDates.isEmpty
                || (unknownDateCount > 0 && candidate.excludesUnknownDate)
        }
    }

    private static func synchronizedNumericRange(
        from: Double,
        to: Double,
        wasActive: Bool,
        available: ClosedRange<Double>?
    ) -> (from: Double, to: Double, isActive: Bool) {
        guard let available else { return (0, 0, false) }
        guard wasActive else { return (available.lowerBound, available.upperBound, false) }
        let from = clamp(from, to: available)
        let to = clamp(to, to: available)
        return (
            from,
            to,
            from != available.lowerBound || to != available.upperBound
        )
    }

    private static func clamp<Value: Comparable>(_ value: Value, to range: ClosedRange<Value>) -> Value {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func resetDerivedData() {
        sortedIndices = []
        visibleDayGroups = []
        visibleDayStartIndices = []
        ratingTally = (0, 0, 0)
        availableTypes = []
        availableCameras = []
        availableLenses = []
        availableSubfolders = []
        availableCaptureDates = []
        captureDateRange = nil
        apertureRange = nil
        shutterRange = nil
        isoRange = nil
        typeCounts = [:]
        cameraCounts = [:]
        lensCounts = [:]
        subfolderCounts = [:]
        captureDateCounts = [:]
        unknownDateCount = 0
    }

    // MARK: - Opening a folder

    func promptForSourceFolder() {
        guard !isCleaningUp else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder with photos to review (an SD card's DCIM folder works too)."
        panel.prompt = "Open Folder"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        guard !isCleaningUp else { return }
        let preservesCurrentFilter = sourceFolder?.standardizedFileURL == url.standardizedFileURL
            && !items.isEmpty
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        cleanUpGeneration &+= 1
        sourceFolder = url
        scanError = nil
        phase = .scanning(found: 0)
        // visibleIndices must be cleared in the same turn items is emptied —
        // stale indices into a shrunk array crash any view that renders first.
        visibleIndices = []
        filterDebounce?.cancel()
        filterDebounce = nil
        prefetchDebounce?.cancel()
        prefetchDebounce = nil
        selectedIndices = []
        items = []
        resetDerivedData()
        if !preservesCurrentFilter {
            filter = PhotoFilter()
            sort = PhotoSort()
        }
        undoStack = []
        isClearAllRatingsConfirmationPresented = false
        pendingCleanUp = nil
        addToRecents(url)

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let scanned = try FolderScanner.scan(url, isCancelled: { Task.isCancelled }) { count in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.scanGeneration == generation,
                              self.sourceFolder == url else { return }
                        if case .scanning = self.phase {
                            self.phase = .scanning(found: count)
                        }
                    }
                }
                try Task.checkCancellation()
                let savedSession = await self.persistence.read(for: url)
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.scanGeneration == generation else { return }
                    self.scanTask = nil
                    self.finishScan(
                        url: url,
                        generation: generation,
                        scanned: scanned,
                        savedSession: savedSession
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.scanGeneration == generation, self.sourceFolder == url else { return }
                    self.scanTask = nil
                    guard !(error is CancellationError) else { return }
                    self.scanError = error.localizedDescription
                    self.phase = .welcome
                }
            }
        }
    }

    /// Stops the active folder walk and returns immediately to the welcome
    /// screen. `closeSession` also advances `scanGeneration`, so any detached
    /// work that finishes after cancellation cannot apply partial results.
    func cancelScan() {
        guard case .scanning = phase else { return }
        closeSession()
    }

    private func finishScan(
        url: URL,
        generation: UInt64,
        scanned: [PhotoItem],
        savedSession: SessionFile?
    ) {
        guard sourceFolder == url, scanGeneration == generation else { return }
        var loaded = scanned
        // Restore prior ratings from the sidecar file, if present.
        if let session = savedSession {
            var ratingByFilename: [String: (Rating, Date?)] = [:]
            for entry in session.entries {
                ratingByFilename[entry.filename] = (Rating(rawValue: entry.rating) ?? .undecided, entry.ratedAt)
            }
            for i in loaded.indices {
                if let (rating, ratedAt) = ratingByFilename[loaded[i].id] {
                    loaded[i].rating = rating
                    loaded[i].ratedAt = ratedAt
                }
            }
        }
        items = loaded
        rebuildDerivedData()
        // Resume from the first undecided photo.
        currentIndex = loaded.firstIndex(where: { $0.rating == .undecided }) ?? 0
        let filterAlreadyApplied = synchronizeFilterRangesWithAvailableData()
        // Recompute visibility (a re-scan keeps the active filter; it may
        // also snap currentIndex onto a visible photo).
        if !filterAlreadyApplied { applyFilter() }
        phase = loaded.isEmpty ? .welcome : .ready
        if loaded.isEmpty {
            scanError = "No supported photos (.NEF, .RAF, .JPG, .JPEG, .TIF) were found in that folder."
        } else {
            saveSession()
        }
    }

    /// Re-scan the current folder to pick up newly added photos.
    /// Existing ratings survive: they're saved to the sidecar first,
    /// and the scan restores them by filename.
    func rescan() {
        guard !isCleaningUp, let folder = sourceFolder else { return }
        saveDebounce?.cancel()
        guard let request = makeSaveRequest() else {
            openFolder(folder)
            return
        }
        Task {
            await persistence.save(request.session, for: request.folder, sequence: request.sequence)
            guard sourceFolder == folder else { return }
            openFolder(folder)
        }
    }

    // MARK: - Multi-selection

    /// What a rating (F/D) applies to: the multi-selection when one is
    /// active, otherwise just the current photo.
    var effectiveSelection: Set<Int> {
        if !selectedIndices.isEmpty { return selectedIndices }
        // `applyFilter` guarantees currentIndex is visible whenever the result
        // is nonempty. With zero matches, empty must remain truly empty so
        // rating and Clean Up cannot act on a hidden former current photo.
        return !visibleIndices.isEmpty && items.indices.contains(currentIndex) ? [currentIndex] : []
    }

    func clearSelection() {
        selectedIndices = []
    }

    /// Routes a thumbnail click by modifier key — shared by the Browser and
    /// Grid views so both respond identically. `plainClick` runs when no
    /// modifier is held (the Browser jumps; the Grid cycles rating).
    func handleThumbnailClick(at index: Int, plainClick: () -> Void) {
        guard !isCleaningUp else { return }
        if NSEvent.modifierFlags.contains(.shift) {
            selectRange(to: index)
        } else if NSEvent.modifierFlags.contains(.command) {
            toggleSelection(of: index)
        } else {
            plainClick()
        }
    }

    /// ⇧-click: select every visible photo between the current one (the
    /// anchor) and the clicked one, both included. The anchor stays current,
    /// so another ⇧-click re-ranges from the same photo.
    func selectRange(to index: Int) {
        guard !isCleaningUp else { return }
        guard let target = visibleIndices.firstIndex(of: index) else { return }
        let anchor = visibleIndices.firstIndex(of: currentIndex) ?? target
        selectedIndices = Set(visibleIndices[min(anchor, target)...max(anchor, target)])
    }

    /// ⌘-click: add or remove a single photo.
    func toggleSelection(of index: Int) {
        guard !isCleaningUp else { return }
        guard items.indices.contains(index) else { return }
        var set = effectiveSelection
        if set.contains(index), set.count > 1 {
            set.remove(index)
        } else {
            set.insert(index)
        }
        // A selection of just the current photo is the normal single state.
        selectedIndices = (set == [currentIndex]) ? [] : set
        // Keep the current photo inside the selection so F/D act where expected.
        if !selectedIndices.isEmpty, !selectedIndices.contains(currentIndex) {
            currentIndex = selectedIndices.contains(index) ? index : (selectedIndices.min() ?? currentIndex)
            prefetchAroundCurrent()
        }
    }

    /// ⌘⇧← / ⌘⇧→: select from the current photo to the first or last
    /// visible photo, current one included.
    func selectToEdge(forward: Bool) {
        guard !isCleaningUp else { return }
        guard let pos = visibleIndices.firstIndex(of: currentIndex) else { return }
        selectedIndices = Set(forward ? visibleIndices[pos...] : visibleIndices[...pos])
    }

    /// ⌘A: select every photo that passes the current filter.
    func selectAllVisible() {
        guard !isCleaningUp else { return }
        selectedIndices = Set(visibleIndices)
    }

    /// Rubber-band drag in the Grid view: the selection follows the
    /// rectangle live. `currentIndex` is deliberately left alone here —
    /// moving it mid-drag would auto-scroll the grid under the cursor.
    func setSelection(_ indices: Set<Int>) {
        guard !isCleaningUp else { return }
        let valid = indices.filter { items.indices.contains($0) }
        // Called on every drag tick; skip the publish (and the grid/toolbar
        // rebuilds it triggers) when the hit-tested set hasn't changed.
        guard valid != selectedIndices else { return }
        selectedIndices = valid
    }

    /// After a rubber-band drag ends, park the current photo on a selected
    /// one so the keyboard rates what the user just outlined.
    func commitSelectionAnchor() {
        guard !isCleaningUp else { return }
        guard !selectedIndices.isEmpty, !selectedIndices.contains(currentIndex),
              let first = selectedIndices.min() else { return }
        currentIndex = first
        prefetchAroundCurrent()
    }

    // MARK: - Rating

    /// Rates the current photo — or, when a multi-selection is active, every
    /// selected photo at once (one ⌘Z reverts the whole batch) — then jumps
    /// to the next undecided photo.
    func rate(_ rating: Rating) {
        guard !isCleaningUp else { return }
        applyRating(rating, to: effectiveSelection.sorted())
        selectedIndices = []
        advanceToNextUndecided()
    }

    /// Grid click: cycle the clicked photo's rating. Clicking a photo
    /// that's part of a multi-selection gives the whole selection the clicked
    /// photo's next rating in one undoable step; the selection stays so the
    /// user can keep cycling.
    func toggleRating(at index: Int) {
        guard !isCleaningUp else { return }
        guard items.indices.contains(index) else { return }
        let next: Rating
        switch items[index].rating {
        case .undecided: next = .yes
        case .yes: next = .no
        case .no: next = .undecided
        }
        if selectedIndices.count > 1, selectedIndices.contains(index) {
            applyRating(next, to: selectedIndices.sorted())
        } else {
            setIndex(index)
            setRating(next, atIndex: index, recordUndo: true)
        }
    }

    /// Applies one rating to several photos as a single undoable step.
    private func applyRating(_ rating: Rating, to targets: [Int]) {
        let valid = targets.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let changes = valid.map {
            RatingChange(index: $0, previousRating: items[$0].rating, previousRatedAt: items[$0].ratedAt)
        }
        pushUndo(.ratings(changes, previousIndex: currentIndex))
        let now = Date()
        for index in valid {
            transitionRatingCount(from: items[index].rating, to: rating)
            items[index].rating = rating
            items[index].ratedAt = now
        }
        scheduleSave()
    }

    private func setRating(_ rating: Rating, atIndex index: Int, recordUndo: Bool) {
        guard items.indices.contains(index) else { return }
        if recordUndo {
            let change = RatingChange(index: index, previousRating: items[index].rating, previousRatedAt: items[index].ratedAt)
            pushUndo(.ratings([change], previousIndex: currentIndex))
        }
        transitionRatingCount(from: items[index].rating, to: rating)
        items[index].rating = rating
        items[index].ratedAt = Date()
        scheduleSave()
    }

    /// Whether clearing every rating is awaiting confirmation in SessionView.
    @Published var isClearAllRatingsConfirmationPresented = false

    /// Ask before resetting a larger rated set to undecided. Toolbar, menu,
    /// and the bare R shortcut all come through here so the threshold is
    /// consistent: 1–15 ratings clear immediately, while 16+ need approval.
    func requestClearAllRatings() {
        guard !isCleaningUp, ratedCount > 0 else { return }
        if ratedCount > 15 {
            isClearAllRatingsConfirmationPresented = true
        } else {
            clearAllRatings()
        }
    }

    /// Reset every photo to undecided — one undo step brings all ratings back.
    func clearAllRatings() {
        guard !isCleaningUp else { return }
        isClearAllRatingsConfirmationPresented = false
        let changes = items.indices.compactMap { i -> RatingChange? in
            guard items[i].rating != .undecided else { return nil }
            return RatingChange(index: i, previousRating: items[i].rating, previousRatedAt: items[i].ratedAt)
        }
        guard !changes.isEmpty else { return }
        pushUndo(.ratings(changes, previousIndex: currentIndex))
        for i in items.indices {
            items[i].rating = .undecided
            items[i].ratedAt = nil
        }
        ratingTally = (0, 0, items.count)
        scheduleSave()
    }

    private func transitionRatingCount(from old: Rating, to new: Rating) {
        guard old != new else { return }
        switch old {
        case .yes: ratingTally.yes -= 1
        case .no: ratingTally.no -= 1
        case .undecided: ratingTally.undecided -= 1
        }
        switch new {
        case .yes: ratingTally.yes += 1
        case .no: ratingTally.no += 1
        case .undecided: ratingTally.undecided += 1
        }
    }

    /// Whether ⌘Z has anything to undo — drives the toolbar button's state.
    /// (Not @Published, but every undo-stack change happens alongside a
    /// published mutation, so views re-evaluate it at the right moments.)
    var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo(_ step: UndoStep) {
        undoStack.append(step)
        if undoStack.count > 500 { undoStack.removeFirst() }
    }

    func undo() {
        guard !isCleaningUp, let step = undoStack.popLast() else { return }
        // Undo moves the session back in time; a live selection would no
        // longer mean what the user built it for.
        selectedIndices = []
        switch step {
        case .ratings(let changes, let previousIndex):
            for change in changes where items.indices.contains(change.index) {
                transitionRatingCount(from: items[change.index].rating, to: change.previousRating)
                items[change.index].rating = change.previousRating
                items[change.index].ratedAt = change.previousRatedAt
            }
            if !items.isEmpty {
                currentIndex = min(max(previousIndex, 0), items.count - 1)
            }
            scheduleSave()
        case .cleanUp(let removed, let previousIndex):
            undoCleanUp(removed, previousIndex: previousIndex)
        }
    }

    // MARK: - Clean up (move rejected files to the Trash)

    /// Which clean-up action is awaiting the user's confirmation (drives the
    /// confirmation dialog in SessionView; set from the toolbar or menu bar).
    @Published var pendingCleanUp: CleanUpMode?
    /// A problem to report after a clean-up or its undo (some file couldn't
    /// be moved). Nil means the last operation went through completely.
    @Published var cleanUpError: String?
    /// Which photos the rating-based Clean Up actions consider. Filtered is
    /// the safe default; the direct "Move Selected" action ignores this and
    /// always targets the effective selection.
    @Published var cleanUpScope: CleanUpScope = .filtered
    /// While true, photo/session mutations are blocked but scrolling and
    /// inspection remain available. File I/O itself runs off the main actor.
    @Published private(set) var isCleaningUp = false
    @Published private(set) var cleanUpProgress: CleanUpProgress?

    /// The photos a rating-based clean-up would consider. The direct selection
    /// action bypasses this property in `cleanUpTargets`.
    private var cleanUpCandidates: [Int] {
        cleanUpScope.candidateIndices(
            all: items.indices,
            filtered: visibleIndices,
            selected: effectiveSelection
        )
    }

    /// Menu enablement only needs to know whether one target exists. Avoid
    /// materializing the entire all-photo candidate array on every toolbar
    /// refresh; the action itself still resolves an exact ordered snapshot.
    private func cleanUpCandidatesContain(_ predicate: (Int) -> Bool) -> Bool {
        switch cleanUpScope {
        case .all:
            return items.indices.contains(where: predicate)
        case .filtered:
            return visibleIndices.contains(where: predicate)
        case .selected:
            return effectiveSelection.contains(where: predicate)
        }
    }

    /// Live candidate totals shown beside the three inline scope choices.
    func cleanUpScopeCount(for scope: CleanUpScope) -> Int {
        switch scope {
        case .all: return items.count
        case .filtered: return visibleIndices.count
        case .selected: return effectiveSelection.count
        }
    }

    /// Exactly which photos a clean-up mode would remove.
    private func cleanUpTargets(for mode: CleanUpMode) -> [Int] {
        switch mode {
        case .selection:
            return effectiveSelection.sorted()
        case .trashNo:
            return cleanUpCandidates.filter { items[$0].rating == .no }
        case .keepOnlyYes:
            return cleanUpCandidates.filter { items[$0].rating != .yes }
        }
    }

    /// Whether a clean-up mode has anything to remove — drives the menu
    /// items' enabled state. Short-circuits instead of building and counting
    /// the whole target list on every toolbar render.
    func hasCleanUpTargets(for mode: CleanUpMode) -> Bool {
        switch mode {
        case .selection:
            return !effectiveSelection.isEmpty
        case .trashNo:
            return cleanUpCandidatesContain { items[$0].rating == .no }
        case .keepOnlyYes:
            return cleanUpCandidatesContain { items[$0].rating != .yes }
        }
    }

    /// How many photos (and actual files, counting RAW+JPEG pairs as two)
    /// a clean-up mode would move to the Trash, respecting the chosen scope.
    /// Only needed once, when the confirmation dialog opens.
    func cleanUpCounts(for mode: CleanUpMode) -> (photos: Int, files: Int, bytes: Int64) {
        let doomed = cleanUpTargets(for: mode).map { items[$0] }
        return (
            doomed.count,
            doomed.reduce(0) { $0 + $1.allURLs.count },
            doomed.reduce(0) { $0 + $1.totalFileSize }
        )
    }

    /// Menu label for trashing the selection, with a live count. Lives on the
    /// store so the toolbar menu and the File menu share one source of truth.
    var selectionCleanUpTitle: String {
        let count = effectiveSelection.count
        return count > 1 ? "Move \(count) Selected to Trash…" : "Move Selected to Trash…"
    }

    /// Flushes a pending search debounce before presenting counts, ensuring
    /// the confirmation describes the exact set that will be moved.
    func requestCleanUp(_ mode: CleanUpMode) {
        guard !isCleaningUp else { return }
        flushPendingFilter()
        pendingCleanUp = mode
    }

    /// Moves every photo the mode rejects within the chosen scope to the
    /// macOS Trash — never a permanent delete. One ⌘Z brings the whole batch
    /// back. A photo is only removed if *all* its files could be trashed; on a
    /// partial failure its already-trashed files are put back. If that
    /// rollback also fails, the app reports the inconsistent pair explicitly.
    func performCleanUp(_ mode: CleanUpMode) {
        guard !isCleaningUp else { return }
        flushPendingFilter()
        // Resolve targets first — .selection reads the live selection —
        // then drop it: indices are about to shift.
        let targets = cleanUpTargets(for: mode)
        let snapshots = targets.compactMap { index in
            items.indices.contains(index) ? CleanUpPhotoSnapshot(index: index, item: items[index]) : nil
        }
        guard !snapshots.isEmpty else { return }
        let previousIndex = currentIndex
        cleanUpGeneration &+= 1
        let generation = cleanUpGeneration
        pendingCleanUp = nil
        selectedIndices = []
        isCleaningUp = true
        let total = snapshots.reduce(0) { $0 + $1.item.allURLs.count }
        cleanUpProgress = CleanUpProgress(action: .movingToTrash, done: 0, total: total)
        let progressReporter = makeCleanUpProgressReporter(action: .movingToTrash, generation: generation)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CleanUpWorker.moveToTrash(snapshots, progress: progressReporter)
            await self?.finishCleanUp(result, previousIndex: previousIndex, generation: generation)
        }
    }

    private func finishCleanUp(_ result: TrashBatchResult, previousIndex: Int, generation: UInt64) {
        guard generation == cleanUpGeneration, isCleaningUp else { return }
        let removed = result.succeeded.map {
            RemovedPhoto(index: $0.index, item: $0.item, trashedFiles: $0.files)
        }
        if !removed.isEmpty {
            let removedIndices = Set(removed.map(\.index))
            items = items.enumerated().filter { !removedIndices.contains($0.offset) }.map(\.element)
            let removedBefore = removed.filter { $0.index < previousIndex }.count
            currentIndex = min(max(previousIndex - removedBefore, 0), max(items.count - 1, 0))
            pushUndo(.cleanUp(removed, previousIndex: previousIndex))
            rebuildDerivedData()
            if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
            saveDebounce?.cancel()
            saveSession()
        }
        isCleaningUp = false
        cleanUpProgress = nil
        if result.failedPhotos > 0 {
            let message: String
            if result.inconsistentPhotos > 0 {
                message = "\(result.failedPhotos) photo\(result.failedPhotos == 1 ? "" : "s") couldn't be moved completely. "
                    + "For \(result.inconsistentPhotos), rollback also failed; check both the source folder and Trash."
            } else {
                message = result.failedPhotos == 1
                    ? "1 photo couldn't be moved to the Trash and stayed in the folder."
                    : "\(result.failedPhotos) photos couldn't be moved to the Trash and stayed in the folder."
            }
            cleanUpError = message
        }
    }

    /// Brings a cleaned-up batch back: moves each file out of the Trash and
    /// reinserts the photos at their original positions (ascending index
    /// order, so every photo lands exactly where it was).
    private func undoCleanUp(_ removed: [RemovedPhoto], previousIndex: Int) {
        guard !isCleaningUp else { return }
        let snapshots = removed.map {
            TrashedPhotoSnapshot(index: $0.index, item: $0.item, files: $0.trashedFiles)
        }
        cleanUpGeneration &+= 1
        let generation = cleanUpGeneration
        isCleaningUp = true
        let total = snapshots.reduce(0) { $0 + $1.files.count }
        cleanUpProgress = CleanUpProgress(action: .restoring, done: 0, total: total)
        let progressReporter = makeCleanUpProgressReporter(action: .restoring, generation: generation)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CleanUpWorker.restore(snapshots, progress: progressReporter)
            await self?.finishUndoCleanUp(
                result,
                allRemovedIndices: Set(removed.map(\.index)),
                previousIndex: previousIndex,
                generation: generation
            )
        }
    }

    private func makeCleanUpProgressReporter(
        action: CleanUpProgress.Action,
        generation: UInt64
    ) -> CleanUpWorker.Progress {
        { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self, self.cleanUpGeneration == generation, self.isCleaningUp else { return }
                self.cleanUpProgress = CleanUpProgress(action: action, done: done, total: total)
            }
        }
    }

    private func finishUndoCleanUp(
        _ result: RestoreBatchResult,
        allRemovedIndices: Set<Int>,
        previousIndex: Int,
        generation: UInt64
    ) {
        guard generation == cleanUpGeneration, isCleaningUp else { return }
        items = CleanUpWorker.mergeRestoredItems(
            survivors: items,
            allRemovedIndices: allRemovedIndices,
            restored: result.restored
        )
        if result.lostPhotos > 0 {
            // Some photos are gone for good (Trash emptied?). Older undo steps'
            // indices no longer line up with `items`, so drop them rather than
            // risk restoring a rating onto the wrong photo.
            undoStack.removeAll()
            cleanUpError = result.lostPhotos == 1
                ? "1 photo couldn't be restored from the Trash — it may have been deleted there."
                : "\(result.lostPhotos) photos couldn't be restored from the Trash — they may have been deleted there."
            if result.inconsistentPhotos > 0 {
                cleanUpError? += " For \(result.inconsistentPhotos), rollback also failed; check both the source folder and Trash."
            }
        }
        if !items.isEmpty {
            currentIndex = min(max(previousIndex, 0), items.count - 1)
        }
        rebuildDerivedData()
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        saveDebounce?.cancel()
        saveSession()
        isCleaningUp = false
        cleanUpProgress = nil
    }

    // MARK: - Navigation (moves through *visible* photos only)

    func goNext() { stepVisible(1) }
    func goPrevious() { stepVisible(-1) }

    /// Moves to the photo in the same grid column on the row above or below.
    /// Each day group starts a new grid, so crossing a group boundary lands in
    /// the nearest matching column of the adjacent day's first/last row.
    func goVertical(_ delta: Int) {
        guard !visibleDayGroups.isEmpty else { return }
        guard let groupIndex = visibleDayGroups.firstIndex(where: { $0.contains(currentIndex) }) else {
            setIndex(visibleIndices[0])
            return
        }
        let group = visibleDayGroups[groupIndex]
        guard let position = group.firstIndex(of: currentIndex) else { return }

        let columns = max(gridColumnCount, 1)
        let row = position / columns
        let column = position % columns
        let target: Int?

        if delta < 0 {
            if row > 0 {
                target = group[min((row - 1) * columns + column, group.count - 1)]
            } else if groupIndex > 0 {
                let previous = visibleDayGroups[groupIndex - 1]
                let lastRowStart = (previous.count - 1) / columns * columns
                target = previous[min(lastRowStart + column, previous.count - 1)]
            } else {
                target = nil
            }
        } else if delta > 0 {
            let nextRowStart = (row + 1) * columns
            if nextRowStart < group.count {
                target = group[min(nextRowStart + column, group.count - 1)]
            } else if groupIndex + 1 < visibleDayGroups.count {
                let next = visibleDayGroups[groupIndex + 1]
                target = next[min(column, next.count - 1)]
            } else {
                target = nil
            }
        } else {
            target = nil
        }

        if let target {
            setIndex(target)
        }
    }

    /// Receives the number of columns calculated by the rendered Grid view.
    func setGridColumnCount(_ count: Int) {
        let count = max(count, 1)
        guard gridColumnCount != count else { return }
        gridColumnCount = count
    }

    private func stepVisible(_ delta: Int) {
        guard !visibleIndices.isEmpty else { return }
        guard let pos = visibleIndices.firstIndex(of: currentIndex) else {
            setIndex(visibleIndices[0])
            return
        }
        let newPos = min(max(pos + delta, 0), visibleIndices.count - 1)
        setIndex(visibleIndices[newPos])
    }

    func setIndex(_ index: Int) {
        guard !isCleaningUp, !items.isEmpty else { return }
        // Plain navigation (click, arrow key) collapses any multi-selection.
        selectedIndices = []
        let clamped = min(max(index, 0), items.count - 1)
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        prefetchAroundCurrent()
    }

    private func advanceToNextUndecided() {
        guard !visibleIndices.isEmpty else { return }
        let pos = visibleIndices.firstIndex(of: currentIndex) ?? 0
        // Search forward from the current photo, wrapping around once.
        let count = visibleIndices.count
        for offset in 1...count {
            let candidate = visibleIndices[(pos + offset) % count]
            if items[candidate].rating == .undecided {
                currentIndex = candidate
                prefetchAroundCurrent()
                return
            }
        }
        // Nothing undecided left: just step forward if possible.
        stepVisible(1)
    }

    func toggleViewMode() {
        viewMode = (viewMode == .gallery) ? .grid : .gallery
    }

    func toggleZoom(_ mode: ZoomMode) {
        zoomMode = (zoomMode == mode) ? .fit : mode
    }

    /// ⌘+ / ⌘− in the Grid view: bigger thumbnails mean fewer per row.
    func zoomGrid(larger: Bool) {
        let next = larger ? gridThumbSize * 1.25 : gridThumbSize / 1.25
        gridThumbSize = min(max(next, 90), 400)
    }

    private func prefetchAroundCurrent() {
        prefetchDebounce?.cancel()
        prefetchDebounce = nil
        // Prefetch the neighbouring *visible* photos, so filtered-out files
        // in between don't waste the warm-up window.
        guard let pos = visibleIndices.firstIndex(of: currentIndex) else { return }
        let windowOffsets = [1, 2, 3, -1]
        let photos = windowOffsets.compactMap { offset -> PhotoItem? in
            let p = pos + offset
            guard visibleIndices.indices.contains(p) else { return nil }
            let item = items[visibleIndices[p]]
            return item.isSupported ? item : nil
        }
        // Collapse repeated navigation/filter updates into one neighbourhood
        // warm-up. The visible image itself still starts immediately.
        let work = DispatchWorkItem {
            ImagePipeline.shared.prefetchFullImages(items: photos)
        }
        prefetchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: - Session persistence

    private func scheduleSave() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveSession() }
        }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveSession() {
        guard let request = makeSaveRequest() else { return }
        pendingPersistenceTask = Task.detached { [persistence] in
            await persistence.save(request.session, for: request.folder, sequence: request.sequence)
        }
    }

    /// `willTerminate` cannot await an actor. Queue the final, newest snapshot
    /// through the same persistence actor and briefly hold termination so a
    /// last-second rating is not lost or overwritten by an older queued save.
    func saveSessionBeforeTermination() {
        let finalTask: Task<Void, Never>?
        if let request = makeSaveRequest() {
            let task = Task.detached { [persistence] in
                await persistence.save(request.session, for: request.folder, sequence: request.sequence)
            }
            pendingPersistenceTask = task
            finalTask = task
        } else {
            // `closeSession` captures its snapshot before clearing UI state.
            // If Quit follows immediately, wait for that already-queued save
            // even though there is no longer a live session to snapshot.
            finalTask = pendingPersistenceTask
        }
        guard let finalTask else { return }
        let completion = DispatchSemaphore(value: 0)
        Task.detached {
            await finalTask.value
            completion.signal()
        }
        _ = completion.wait(timeout: .now() + 3)
    }

    private struct SaveRequest: Sendable {
        let folder: URL
        let session: SessionFile
        let sequence: UInt64
    }

    /// Capture value-semantic session data on the main actor, then let the
    /// persistence actor perform the expensive encoding and file I/O.
    private func makeSaveRequest() -> SaveRequest? {
        guard let folder = sourceFolder, case .ready = phase else { return nil }
        let session = SessionFile(
            version: 1,
            sourcePath: folder.path,
            scannedAt: Date(),
            entries: items.map { item in
                SessionEntry(
                    filename: item.id,
                    pairedFilename: item.pairedURL?.lastPathComponent,
                    rating: item.rating.rawValue,
                    ratedAt: item.ratedAt
                )
            }
        )
        saveSequence &+= 1
        return SaveRequest(folder: folder, session: session, sequence: saveSequence)
    }

    // MARK: - Recent folders

    private func loadRecents() {
        let paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        recentFolders = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addToRecents(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > 8 { paths = Array(paths.prefix(8)) }
        UserDefaults.standard.set(paths, forKey: "recentFolders")
        recentFolders = paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Going back to the welcome screen

    func closeSession() {
        guard !isCleaningUp else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        cleanUpGeneration &+= 1
        saveDebounce?.cancel()
        filterDebounce?.cancel()
        filterDebounce = nil
        prefetchDebounce?.cancel()
        prefetchDebounce = nil
        saveSession()
        items = []
        resetDerivedData()
        sourceFolder = nil
        undoStack = []
        selectedIndices = []
        isClearAllRatingsConfirmationPresented = false
        pendingCleanUp = nil
        cleanUpError = nil
        currentIndex = 0
        viewMode = .gallery
        filter = PhotoFilter()
        sort = PhotoSort()
        visibleIndices = []
        isFilterPresented = false
        phase = .welcome
    }
}
