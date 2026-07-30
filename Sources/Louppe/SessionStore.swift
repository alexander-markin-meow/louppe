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

/// One source of truth for filesystem operations that must not overlap or be
/// interrupted by Quit, folder replacement, or updater installation.
enum FileOperationKind: Equatable, Sendable {
    case cleanUp
    case exportCopy
    case exportMove
}

/// The app's single source of truth: the loaded session (photos + ratings),
/// navigation, undo, view state, and persistence to the sidecar file.
@MainActor
final class SessionStore: ObservableObject {
    @Published var phase: AppPhase = .welcome
    @Published var items: [PhotoItem] = []
    @Published var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue { videoPlayback.stop() }
        }
    }
    @Published var viewMode: ViewMode = .gallery
    @Published var showMetadataPanel = true
    @Published var showBrowser = true
    @Published var zoomMode: ZoomMode = .fit
    @Published var showClippingWarnings = false
    let actualSizeViewport = ActualSizeViewport()
    @Published var gridThumbSize: CGFloat = 170
    /// Number of adaptive columns currently visible in the Grid view.
    /// GridView updates this from the actual available window width.
    // Navigation reads this value, but no view renders it. Publishing it would
    // force a redundant second grid redraw after every resize/thumbnail zoom.
    private(set) var gridColumnCount = 1
    @Published var isExportPresented = false
    @Published var isFilterPresented = false
    @Published var isSortPresented = false
    /// Whether same-named RAW and JPEG files are reviewed and acted on as one
    /// photo item. The safe default keeps the existing RAW+JPEG behavior.
    @Published private(set) var rawJPEGPairingMode: RawJPEGPairingMode = .together
    /// The first transition to separate review may read metadata from hidden
    /// JPEG partners. The current session remains visible while this is true.
    @Published private(set) var isChangingRawJPEGPairingMode = false
    /// The "Divide into groups" switch at the end of the sort popover. One
    /// global setting: off hides every divider whatever the sort key is.
    @Published var isGroupingEnabled = true {
        didSet {
            if isGroupingEnabled != oldValue { rebuildVisibleGroups() }
        }
    }
    /// In-flight big-photo decodes (a count, so overlapping loads during fast
    /// arrow-key navigation can't blank the spinner early). The toolbar shows
    /// a small spinner while it's above zero.
    @Published var fullImageLoads = 0
    @Published var scanError: String?
    /// A non-blocking warning when ratings are safe only in Louppe's backup,
    /// or are not currently persisted anywhere. A successful sidecar write
    /// clears it automatically.
    @Published private(set) var persistenceWarning: String?
    @Published var recentFolders: [URL] = []
    let videoPlayback = VideoPlaybackController()

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
    /// Same visible order, split into runs of the active sort key's value
    /// (days, cameras, subfolders…) for the Grid view. Rebuilt only when
    /// filter/sort/session structure changes, not on selection drag.
    @Published private(set) var visibleGroups: [PhotoGroup] = []
    /// Item index → header title for the Browser strip, covering every group
    /// start (including the first). Empty when division is off.
    @Published private(set) var visibleGroupTitles: [Int: String] = [:]

    /// The multi-selection (absolute indices into `items`). Empty is the
    /// normal single-photo state: the selection is just `currentIndex`.
    /// Selection gestures keep `currentIndex` inside the set as the anchor.
    @Published private(set) var selectedIndices: Set<Int> = []
    /// Stable authority for the multi-selection. `selectedIndices` is its
    /// render-facing projection into the current `items` generation.
    private var selectionState = SelectionState()

    private(set) var sourceFolder: URL?
    @Published private(set) var activeFileOperation: FileOperationKind?
    @Published private(set) var isSessionTransitioning = false
    @Published private(set) var isRecoveringInterruptedOperations = false
    @Published private(set) var operationRecoveryReport:
        FileOperationJournal.RecoveryReport?
    @Published private(set) var recoveryNeedsAttention = false
    var isFileOperationRunning: Bool {
        activeFileOperation != nil
            || isSessionTransitioning
            || isRecoveringInterruptedOperations
            || recoveryNeedsAttention
    }
    var isCleaningUp: Bool { activeFileOperation == .cleanUp }
    var isCopyingExport: Bool { activeFileOperation == .exportCopy }
    var isMovingExport: Bool { activeFileOperation == .exportMove }
    var isExporting: Bool { isCopyingExport || isMovingExport }

    /// One undo step can hold several photo changes (e.g. "clear all"),
    /// so a single ⌘Z restores the whole batch.
    private struct RatingChange {
        let fileID: String
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
        case ratings([RatingChange], previousFileID: String?)
        case cleanUp(
            [RemovedPhoto],
            previousItemID: String?,
            previousIndex: Int
        )
    }
    private var undoStack: [UndoStep] = []
    private var saveDebounce: DispatchWorkItem?
    private var pendingPersistenceTask: Task<SessionPersistence.SaveResult, Never>?
    private var pendingPersistenceRequest: SaveRequest?
    private var retrySaveRequest: SaveRequest?
    private var filterDebounce: DispatchWorkItem?
    private var prefetchDebounce: DispatchWorkItem?
    private var scanTask: Task<Void, Never>?
    private let persistence = SessionPersistence()
    private var saveSequence: UInt64 = 0
    private var latestReportedSaveSequence: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var folderOpenGeneration: UInt64 = 0
    private var cleanUpGeneration: UInt64 = 0
    private var deferredFolderOpen: URL?
    private var shouldRescanAfterRecovery = false
    private var preparedIndex = PreparedSessionIndex()
    private struct ScanResumeIdentity {
        let folder: URL
        let currentItemID: String?
        let selectedItemIDs: Set<String>
    }
    private var scanResumeIdentity: ScanResumeIdentity?
    private var ratingTally = (yes: 0, no: 0, undecided: 0)
    private var mixedRatingCount = 0
    /// Physical ids include hidden JPEG partners, so rating undo remains
    /// stable across an in-memory pairing projection.
    private var itemIndexByFileID: [String: Int] = [:]

    @Published private(set) var availableTypes: [String] = []
    @Published private(set) var availableMediaKinds: [MediaKind] = []
    @Published private(set) var availableCameras: [String] = []
    @Published private(set) var availableLenses: [String] = []
    @Published private(set) var availableSubfolders: [String] = []
    @Published private(set) var availableCaptureDates: [Date] = []
    @Published private(set) var captureDateRange: ClosedRange<Date>?
    @Published private(set) var apertureRange: ClosedRange<Double>?
    @Published private(set) var shutterRange: ClosedRange<Double>?
    @Published private(set) var isoRange: ClosedRange<Double>?
    @Published private(set) var durationRange: ClosedRange<Double>?
    @Published private(set) var typeCounts: [String: Int] = [:]
    @Published private(set) var mediaKindCounts: [MediaKind: Int] = [:]
    @Published private(set) var cameraCounts: [String: Int] = [:]
    @Published private(set) var lensCounts: [String: Int] = [:]
    @Published private(set) var subfolderCounts: [String: Int] = [:]
    @Published private(set) var captureDateCounts: [Date: Int] = [:]
    @Published private(set) var unknownDateCount = 0

    nonisolated static let sidecarName = SessionConstants.sidecarName

    init() {
        loadRecents()
        if FileOperationJournal.hasPendingOperations() {
            beginInterruptedOperationRecovery()
        }
    }

    // MARK: - Interrupted file-operation recovery

    /// Retries every still-active journal. Existing files are never
    /// overwritten; an unavailable volume or identity mismatch remains
    /// visible for another retry instead of being guessed around.
    func retryInterruptedOperationRecovery() {
        beginInterruptedOperationRecovery()
    }

    func dismissOperationRecoveryReport() {
        operationRecoveryReport = nil
    }

    private func beginInterruptedOperationRecovery(
        rescanOnSuccess: Bool = false
    ) {
        shouldRescanAfterRecovery =
            shouldRescanAfterRecovery || rescanOnSuccess
        guard !isRecoveringInterruptedOperations else { return }
        operationRecoveryReport = nil
        recoveryNeedsAttention = false
        isRecoveringInterruptedOperations = true

        let worker = Task.detached(priority: .userInitiated) {
            FileOperationJournal.recoverPendingOperations()
        }
        Task { @MainActor [weak self] in
            let report = await worker.value
            guard let self else { return }
            self.isRecoveringInterruptedOperations = false
            self.operationRecoveryReport = report
            if report.hasUnresolvedFiles {
                self.recoveryNeedsAttention = true
                return
            }

            self.recoveryNeedsAttention = false
            let deferredFolder = self.deferredFolderOpen
            self.deferredFolderOpen = nil
            let rescan = self.shouldRescanAfterRecovery
            self.shouldRescanAfterRecovery = false
            if let deferredFolder {
                self.openFolder(deferredFolder)
            } else if rescan {
                self.rescan()
            }
        }
    }

    // MARK: - Counts

    var yesCount: Int { ratingTally.yes }
    var noCount: Int { ratingTally.no }
    var undecidedCount: Int { ratingTally.undecided }
    var mixedCount: Int { mixedRatingCount }
    var ratedCount: Int { ratingTally.yes + ratingTally.no + mixedRatingCount }

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

    var canToggleClippingWarnings: Bool {
        guard viewMode == .gallery,
              selectedIndices.count <= 1,
              let currentItem
        else { return false }
        return currentItem.mediaKind == .photo && currentItem.isSupported
    }

    private var currentItemID: String? {
        items.indices.contains(currentIndex) ? items[currentIndex].id : nil
    }

    var currentVisiblePosition: Int? {
        preparedIndex.location(forItemIndex: currentIndex)?.position
    }

    /// Stable Browser row identities are rebuilt with the prepared visibility
    /// generation, not on every unrelated `SessionStore` publication.
    var browserEntries: [PreparedSessionIndex.VisibleEntry] {
        preparedIndex.visibleEntries
    }

    private func setSelectionIndices(_ indices: Set<Int>) {
        let changed = selectionState.replace(with: indices, items: items)
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    private func restoreSelection(
        itemIDs: Set<String>,
        visibleOnly: Bool
    ) {
        let previousIndices = selectionState.indices
        let replacementCurrent = selectionState.restore(
            itemIDs: itemIDs,
            items: items,
            preparedIndex: preparedIndex,
            visibleOnly: visibleOnly,
            currentIndex: currentIndex
        )
        if selectionState.indices != previousIndices {
            selectedIndices = selectionState.indices
        }
        if let replacementCurrent {
            currentIndex = replacementCurrent
        }
    }

    private func restoreCurrentItem(
        itemID: String?,
        fallbackIndex: Int
    ) {
        guard !items.isEmpty else {
            currentIndex = 0
            return
        }
        if let itemID, let index = preparedIndex.itemIndex(forID: itemID) {
            currentIndex = index
        } else {
            currentIndex = min(max(fallbackIndex, 0), items.count - 1)
        }
    }

    private func restoreCurrentFile(
        fileID: String?,
        fallbackIndex: Int
    ) {
        guard !items.isEmpty else {
            currentIndex = 0
            return
        }
        if let fileID, let index = itemIndexByFileID[fileID] {
            currentIndex = index
        } else {
            currentIndex = min(max(fallbackIndex, 0), items.count - 1)
        }
    }

    // MARK: - Filtering

    private func applyFilter() {
        preparedIndex.applyFilter(
            filter,
            to: items,
            sort: sort,
            isGroupingEnabled: isGroupingEnabled
        )
        publishPreparedVisibility()
        // Photos that just got filtered out must leave the selection too —
        // an invisible photo shouldn't silently receive a rating.
        if !selectedIndices.isEmpty {
            let changed = selectionState.retainVisible(
                items: items,
                preparedIndex: preparedIndex
            )
            if changed {
                selectedIndices = selectionState.indices
            }
        }
        // Keep the current photo visible: snap to the nearest photo that
        // passes the filter (forward first, else the last visible one).
        if !visibleIndices.isEmpty,
           preparedIndex.location(forItemIndex: currentIndex) == nil {
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
        rebuildFileItemIndex()
        preparedIndex.rebuildItems(items, sort: sort)
    }

    private func rebuildFileItemIndex() {
        var indexByFileID: [String: Int] = [:]
        indexByFileID.reserveCapacity(
            items.reduce(0) { $0 + $1.individualFiles.count }
        )
        for (index, item) in items.enumerated() {
            for file in item.individualFiles {
                indexByFileID[file.id] = index
            }
        }
        itemIndexByFileID = indexByFileID
    }

    private func rebuildVisibleGroups() {
        preparedIndex.rebuildGroups(
            for: items,
            sort: sort,
            isGroupingEnabled: isGroupingEnabled
        )
        publishPreparedVisibility()
    }

    private func publishPreparedVisibility() {
        visibleIndices = preparedIndex.visibleIndices
        visibleGroups = preparedIndex.visibleGroups
        visibleGroupTitles = preparedIndex.visibleGroupTitles
    }

    /// Rebuild all values derived from session structure in one pass. Ratings
    /// use incremental updates during normal culling; structural operations are
    /// rare enough that a single complete rebuild is clearer and safer.
    private func rebuildDerivedData() {
        var tally = (yes: 0, no: 0, undecided: 0)
        var mixed = 0
        var types: [String: Int] = [:]
        var mediaKinds: [MediaKind: Int] = [:]
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
        var minimumDuration: Double?
        var maximumDuration: Double?
        for item in items {
            // Keep the three public counts exhaustive: mixed pairs are
            // unresolved and therefore included in `undecidedCount`.
            switch item.ratingState {
            case .yes:
                tally.yes += 1
            case .no:
                tally.no += 1
            case .undecided:
                tally.undecided += 1
            case .mixed:
                tally.undecided += 1
                mixed += 1
            }
            types[item.fileTypeLabel, default: 0] += 1
            mediaKinds[item.mediaKind, default: 0] += 1
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
            if let duration = item.duration, duration.isFinite, duration >= 0 {
                minimumDuration = minimumDuration.map { min($0, duration) } ?? duration
                maximumDuration = maximumDuration.map { max($0, duration) } ?? duration
            }
        }
        ratingTally = tally
        mixedRatingCount = mixed
        typeCounts = types
        mediaKindCounts = mediaKinds
        cameraCounts = cameras
        lensCounts = lenses
        subfolderCounts = subfolders
        availableTypes = types.keys.sorted()
        availableMediaKinds = [.photo, .video].filter { mediaKinds[$0] != nil }
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
        durationRange = Self.closedRange(minimum: minimumDuration, maximum: maximumDuration)
        if let activeID = videoPlayback.itemID, !items.contains(where: { $0.id == activeID }) {
            videoPlayback.stop()
        }
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
        updated.excludedMediaKinds.formIntersection(availableMediaKinds)
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

        let duration = Self.synchronizedNumericRange(
            from: updated.durationFrom,
            to: updated.durationTo,
            wasActive: updated.durationEnabled,
            available: durationRange
        )
        updated.durationFrom = duration.from
        updated.durationTo = duration.to
        updated.durationEnabled = duration.isActive

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
        if let available = durationRange {
            reset.durationFrom = available.lowerBound
            reset.durationTo = available.upperBound
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
        preparedIndex.reset()
        publishPreparedVisibility()
        ratingTally = (0, 0, 0)
        mixedRatingCount = 0
        itemIndexByFileID = [:]
        availableTypes = []
        availableMediaKinds = []
        availableCameras = []
        availableLenses = []
        availableSubfolders = []
        availableCaptureDates = []
        captureDateRange = nil
        apertureRange = nil
        shutterRange = nil
        isoRange = nil
        durationRange = nil
        typeCounts = [:]
        mediaKindCounts = [:]
        cameraCounts = [:]
        lensCounts = [:]
        subfolderCounts = [:]
        captureDateCounts = [:]
        unknownDateCount = 0
    }

    // MARK: - Opening a folder

    func promptForSourceFolder() {
        guard !isFileOperationRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder with photos and videos to review (an SD card's DCIM folder works too)."
        panel.prompt = "Open Folder"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        if isRecoveringInterruptedOperations || recoveryNeedsAttention {
            deferredFolderOpen = url
            return
        }
        guard !isFileOperationRunning else { return }
        folderOpenGeneration &+= 1
        let openGeneration = folderOpenGeneration
        if let currentFolder = sourceFolder,
           currentFolder.standardizedFileURL != url.standardizedFileURL,
           case .ready = phase,
           !items.isEmpty {
            saveDebounce?.cancel()
            saveDebounce = nil
            guard let request = makeSaveRequest() else {
                beginOpeningFolder(url)
                return
            }
            isSessionTransitioning = true
            let task = enqueuePersistenceSave(request)
            Task { @MainActor [weak self] in
                let result = await task.value
                guard let self, self.folderOpenGeneration == openGeneration else { return }
                self.isSessionTransitioning = false
                guard result.canDiscardInMemoryState,
                      self.sourceFolder?.standardizedFileURL
                        == currentFolder.standardizedFileURL else { return }
                self.beginOpeningFolder(url)
            }
            return
        }
        beginOpeningFolder(url)
    }

    private func beginOpeningFolder(_ url: URL) {
        videoPlayback.stop()
        let isSameFolder =
            sourceFolder?.standardizedFileURL == url.standardizedFileURL
        if !isSameFolder {
            actualSizeViewport.reset()
            showClippingWarnings = false
        }
        let preservesCurrentFilter = isSameFolder && !items.isEmpty
        if preservesCurrentFilter {
            scanResumeIdentity = ScanResumeIdentity(
                folder: url.standardizedFileURL,
                currentItemID: currentItemID,
                selectedItemIDs: selectionState.itemIDs
            )
        } else {
            scanResumeIdentity = nil
        }
        if !isSameFolder {
            persistenceWarning = nil
            retrySaveRequest = nil
        }
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
        setSelectionIndices([])
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
        let pairingMode = rawJPEGPairingMode

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // The scan polls cancellation from parallel metadata workers
                // on GCD threads, where `Task.isCancelled` has no task context
                // and silently reads false. Bridge this task's cancellation
                // into a flag that is valid on any thread.
                let cancelFlag = FolderScanner.CancelFlag()
                let scanned = try await withTaskCancellationHandler {
                    try FolderScanner.scan(
                        url,
                        pairingMode: pairingMode,
                        isCancelled: { cancelFlag.isSet }
                    ) { count in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.scanGeneration == generation,
                                  self.sourceFolder == url else { return }
                            if case .scanning = self.phase {
                                self.phase = .scanning(found: count)
                            }
                        }
                    }
                } onCancel: {
                    cancelFlag.set()
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
                        persistenceResult: savedSession
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

    func setRawJPEGPairingMode(_ mode: RawJPEGPairingMode) {
        guard mode != rawJPEGPairingMode, !isFileOperationRunning else { return }
        let previousMode = rawJPEGPairingMode
        rawJPEGPairingMode = mode
        guard let folder = sourceFolder, case .ready = phase, !items.isEmpty else { return }

        // The available type labels change between "RAW + JPEG" and separate
        // "RAW"/"JPEG" entries. Clear only that facet so an old label cannot
        // silently produce a surprising result after the rebuild.
        var updatedFilter = filter
        updatedFilter.excludedTypes = []
        filter = updatedFilter
        flushPendingFilter()

        let sourceItems = items
        let currentFileID = items.indices.contains(currentIndex)
            ? items[currentIndex].primaryFile.id
            : nil
        let selectedFileIDs = Set(
            selectedIndices.flatMap { index in
                items.indices.contains(index)
                    ? items[index].individualFiles.map(\.id)
                    : []
            }
        )
        isSessionTransitioning = true
        isChangingRawJPEGPairingMode = true
        let requestedMode = mode
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let projection = try FolderScanner.projectPairingMode(
                    requestedMode,
                    from: sourceItems,
                    root: folder
                )
                await self?.finishPairingModeChange(
                    projection,
                    requestedMode: requestedMode,
                    folder: folder,
                    currentFileID: currentFileID,
                    selectedFileIDs: selectedFileIDs
                )
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.rawJPEGPairingMode = previousMode
                    self.isChangingRawJPEGPairingMode = false
                    self.isSessionTransitioning = false
                }
            }
        }
    }

    private func finishPairingModeChange(
        _ projection: FolderScanner.PairingProjection,
        requestedMode: RawJPEGPairingMode,
        folder: URL,
        currentFileID: String?,
        selectedFileIDs: Set<String>
    ) {
        guard rawJPEGPairingMode == requestedMode,
              sourceFolder?.standardizedFileURL == folder.standardizedFileURL,
              case .ready = phase else {
            isChangingRawJPEGPairingMode = false
            isSessionTransitioning = false
            return
        }

        setSelectionIndices([])
        items = projection.items
        rebuildDerivedData()
        let currentItemID = currentFileID.flatMap {
            projection.itemIDByFileID[$0]
        }
        restoreCurrentItem(itemID: currentItemID, fallbackIndex: currentIndex)
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        let selectedItemIDs = Set(
            selectedFileIDs.compactMap { projection.itemIDByFileID[$0] }
        )
        restoreSelection(
            itemIDs: selectedItemIDs,
            visibleOnly: true
        )
        prefetchAroundCurrent()
        isChangingRawJPEGPairingMode = false
        isSessionTransitioning = false
        saveSession()
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
        persistenceResult: SessionPersistence.ReadResult
    ) {
        guard sourceFolder == url, scanGeneration == generation else { return }
        if let blockingMessage = persistenceResult.blockingMessage {
            scanResumeIdentity = nil
            items = []
            resetDerivedData()
            visibleIndices = []
            phase = .welcome
            scanError = blockingMessage
            return
        }
        let resumeIdentity = scanResumeIdentity.flatMap {
            $0.folder == url.standardizedFileURL ? $0 : nil
        }
        scanResumeIdentity = nil
        persistenceWarning = persistenceResult.recoveryMessage
        let loaded = scanned
        // Restore prior ratings from the sidecar file, if present.
        if let session = persistenceResult.session {
            var ratingByFilename: [String: (Rating, Date?)] = [:]
            for entry in session.entries {
                let rating = (Rating(rawValue: entry.rating) ?? .undecided, entry.ratedAt)
                ratingByFilename[entry.filename] = rating
                if let pairedFilename = entry.pairedFilename {
                    let parent = (entry.filename as NSString).deletingLastPathComponent
                    let pairedID = parent.isEmpty ? pairedFilename : "\(parent)/\(pairedFilename)"
                    // When a previously paired item is split, both files
                    // inherit the existing decision instead of losing it.
                    ratingByFilename[pairedID] = rating
                }
            }
            for i in loaded.indices {
                for file in loaded[i].individualFiles {
                    if let (rating, ratedAt) = ratingByFilename[file.id] {
                        loaded[i].restoreRating(
                            PhotoFileRatingSnapshot(
                                fileID: file.id,
                                rating: rating,
                                ratedAt: ratedAt
                            )
                        )
                    }
                }
            }
        }
        items = loaded
        rebuildDerivedData()
        let firstUndecided =
            loaded.firstIndex(where: { $0.rating == .undecided }) ?? 0
        restoreCurrentItem(
            itemID: resumeIdentity?.currentItemID,
            fallbackIndex: firstUndecided
        )
        let filterAlreadyApplied = synchronizeFilterRangesWithAvailableData()
        // Recompute visibility (a re-scan keeps the active filter; it may
        // also snap currentIndex onto a visible photo).
        if !filterAlreadyApplied { applyFilter() }
        if let resumeIdentity {
            restoreSelection(
                itemIDs: resumeIdentity.selectedItemIDs,
                visibleOnly: true
            )
            prefetchAroundCurrent()
        }
        phase = loaded.isEmpty ? .welcome : .ready
        if loaded.isEmpty {
            scanError = "No recognised photos or videos were found in that folder."
        } else {
            saveSession()
        }
    }

    /// Re-scan the current folder to pick up newly added photos.
    /// Existing ratings survive: they're saved to the sidecar first,
    /// and the scan restores them by filename.
    func rescan() {
        guard !isFileOperationRunning, let folder = sourceFolder else { return }
        saveDebounce?.cancel()
        guard let request = makeSaveRequest() else {
            openFolder(folder)
            return
        }
        isSessionTransitioning = true
        let task = enqueuePersistenceSave(request)
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self else { return }
            self.isSessionTransitioning = false
            guard result.canDiscardInMemoryState else { return }
            guard self.sourceFolder == folder else { return }
            self.beginOpeningFolder(folder)
        }
    }

    // MARK: - Multi-selection

    /// What a rating (F/D) applies to: the multi-selection when one is
    /// active, otherwise just the current photo.
    var effectiveSelection: Set<Int> {
        selectionState.effectiveSelection(
            currentIndex: currentIndex,
            visibleIndices: visibleIndices,
            itemCount: items.count
        )
    }

    func clearSelection() {
        setSelectionIndices([])
    }

    /// Routes a thumbnail click by modifier key — shared by the Browser and
    /// Grid views so both respond identically. `plainClick` runs when no
    /// modifier is held; both views use it to make the clicked photo current.
    func handleThumbnailClick(at index: Int, plainClick: () -> Void) {
        guard !isFileOperationRunning else { return }
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
        guard !isFileOperationRunning else { return }
        let changed = selectionState.selectRange(
            from: currentIndex,
            to: index,
            visibleIndices: visibleIndices,
            items: items,
            preparedIndex: preparedIndex
        )
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    /// ⌘-click: add or remove a single photo.
    func toggleSelection(of index: Int) {
        guard !isFileOperationRunning else { return }
        let previousIndices = selectionState.indices
        let replacementCurrent = selectionState.toggle(
            index,
            currentIndex: currentIndex,
            visibleIndices: visibleIndices,
            items: items
        )
        if selectionState.indices != previousIndices {
            selectedIndices = selectionState.indices
        }
        // Keep the current photo inside the selection so F/D act where expected.
        if let replacementCurrent {
            currentIndex = replacementCurrent
            prefetchAroundCurrent()
        }
    }

    /// ⌘⇧← / ⌘⇧→: select from the current photo to the first or last
    /// visible photo, current one included.
    func selectToEdge(forward: Bool) {
        guard !isFileOperationRunning else { return }
        let changed = selectionState.selectToEdge(
            from: currentIndex,
            forward: forward,
            visibleIndices: visibleIndices,
            items: items,
            preparedIndex: preparedIndex
        )
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    /// ⌘A: select every photo that passes the current filter.
    func selectAllVisible() {
        guard !isFileOperationRunning else { return }
        let changed = selectionState.selectAllVisible(
            visibleIndices,
            items: items
        )
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    /// Rubber-band drag in the Grid view: the selection follows the
    /// rectangle live. `currentIndex` is deliberately left alone here —
    /// moving it mid-drag would auto-scroll the grid under the cursor.
    func setSelection(_ indices: Set<Int>) {
        guard !isFileOperationRunning else { return }
        // Called on every drag tick; the pure state skips publication (and the
        // grid/toolbar rebuilds it triggers) when the hit-tested set is equal.
        let changed = selectionState.updateRubberBand(indices, items: items)
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    /// After a rubber-band drag ends, park the current photo on a selected
    /// one so the keyboard rates what the user just outlined.
    func commitSelectionAnchor() {
        guard !isFileOperationRunning else { return }
        guard let anchor =
                selectionState.committedAnchor(currentIndex: currentIndex)
        else { return }
        currentIndex = anchor
        prefetchAroundCurrent()
    }

    // MARK: - Rating

    /// Rates the current photo — or, when a multi-selection is active, every
    /// selected photo at once (one ⌘Z reverts the whole batch) — then jumps
    /// to the next undecided photo.
    func rate(_ rating: Rating) {
        guard !isFileOperationRunning else { return }
        applyRating(rating, to: effectiveSelection.sorted())
        setSelectionIndices([])
        advanceToNextUndecided()
    }

    /// Grid rating-control click: cycle the clicked photo's rating. Using the
    /// control on a photo that's part of a multi-selection gives the whole
    /// selection the clicked photo's next rating in one undoable step; the
    /// selection stays so the user can keep cycling.
    func toggleRating(at index: Int) {
        guard !isFileOperationRunning else { return }
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

    /// An explicit rating action for VoiceOver media tiles. Unlike the F/D
    /// review flow this does not advance afterward, because the accessible
    /// action menu belongs to one stable tile. If that tile is part of a
    /// multi-selection, the action follows Grid click behavior and rates the
    /// whole selection in one undoable step.
    func rate(_ rating: Rating, at index: Int) {
        guard !isFileOperationRunning else { return }
        guard items.indices.contains(index) else { return }
        if selectedIndices.count > 1, selectedIndices.contains(index) {
            applyRating(rating, to: selectedIndices.sorted())
        } else {
            setIndex(index)
            setRating(rating, atIndex: index, recordUndo: true)
        }
    }

    /// Applies one rating to several photos as a single undoable step.
    private func applyRating(_ rating: Rating, to targets: [Int]) {
        let valid = targets.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let changes = valid.flatMap { index in
            items[index].ratingSnapshots.map {
                RatingChange(
                    fileID: $0.fileID,
                    previousRating: $0.rating,
                    previousRatedAt: $0.ratedAt
                )
            }
        }
        pushUndo(.ratings(changes, previousFileID: currentItemID))
        let now = Date()
        // Ratings live in each physical file's tiny shared storage. Publish
        // once, then update only the selected records without copying the
        // full immutable metadata array.
        objectWillChange.send()
        for index in valid {
            let previousState = items[index].ratingState
            items[index].setRating(rating, ratedAt: now)
            transitionRatingCount(
                from: previousState,
                to: items[index].ratingState
            )
        }
        scheduleSave()
    }

    private func setRating(_ rating: Rating, atIndex index: Int, recordUndo: Bool) {
        guard items.indices.contains(index) else { return }
        if recordUndo {
            let changes = items[index].ratingSnapshots.map {
                RatingChange(
                    fileID: $0.fileID,
                    previousRating: $0.rating,
                    previousRatedAt: $0.ratedAt
                )
            }
            pushUndo(.ratings(changes, previousFileID: currentItemID))
        }
        let previousState = items[index].ratingState
        objectWillChange.send()
        items[index].setRating(rating, ratedAt: Date())
        transitionRatingCount(
            from: previousState,
            to: items[index].ratingState
        )
        scheduleSave()
    }

    /// Whether clearing every rating is awaiting confirmation in SessionView.
    @Published var isClearAllRatingsConfirmationPresented = false

    /// Ask before resetting a larger rated set to undecided. Toolbar, menu,
    /// and the bare R shortcut all come through here so the threshold is
    /// consistent: 1–15 ratings clear immediately, while 16+ need approval.
    func requestClearAllRatings() {
        guard !isFileOperationRunning, ratedCount > 0 else { return }
        if ratedCount > 15 {
            isClearAllRatingsConfirmationPresented = true
        } else {
            clearAllRatings()
        }
    }

    /// Reset every photo to undecided — one undo step brings all ratings back.
    func clearAllRatings() {
        guard !isFileOperationRunning else { return }
        isClearAllRatingsConfirmationPresented = false
        let changes = items.flatMap { item -> [RatingChange] in
            guard item.hasAnyRating else { return [] }
            return item.ratingSnapshots.compactMap {
                guard $0.rating != .undecided else { return nil }
                return RatingChange(
                    fileID: $0.fileID,
                    previousRating: $0.rating,
                    previousRatedAt: $0.ratedAt
                )
            }
        }
        guard !changes.isEmpty else { return }
        pushUndo(.ratings(changes, previousFileID: currentItemID))
        objectWillChange.send()
        for item in items {
            item.setRating(.undecided, ratedAt: nil)
        }
        ratingTally = (0, 0, items.count)
        mixedRatingCount = 0
        scheduleSave()
    }

    private func transitionRatingCount(
        from old: PhotoItemRatingState,
        to new: PhotoItemRatingState
    ) {
        guard old != new else { return }
        switch old {
        case .yes: ratingTally.yes -= 1
        case .no: ratingTally.no -= 1
        case .undecided: ratingTally.undecided -= 1
        case .mixed:
            ratingTally.undecided -= 1
            mixedRatingCount -= 1
        }
        switch new {
        case .yes: ratingTally.yes += 1
        case .no: ratingTally.no += 1
        case .undecided: ratingTally.undecided += 1
        case .mixed:
            ratingTally.undecided += 1
            mixedRatingCount += 1
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
        guard !isFileOperationRunning, let step = undoStack.popLast() else { return }
        // Undo moves the session back in time; a live selection would no
        // longer mean what the user built it for.
        setSelectionIndices([])
        switch step {
        case .ratings(let changes, let previousFileID):
            let indexedChanges: [(index: Int, change: RatingChange)] =
                changes.compactMap { change in
                    guard let index = itemIndexByFileID[change.fileID],
                          items.indices.contains(index) else { return nil }
                    return (index: index, change: change)
                }
            var previousStates: [Int: PhotoItemRatingState] = [:]
            for (index, _) in indexedChanges {
                previousStates[index] = previousStates[index]
                    ?? items[index].ratingState
            }
            if !indexedChanges.isEmpty {
                objectWillChange.send()
            }
            for (index, change) in indexedChanges {
                items[index].restoreRating(
                    PhotoFileRatingSnapshot(
                        fileID: change.fileID,
                        rating: change.previousRating,
                        ratedAt: change.previousRatedAt
                    )
                )
            }
            for (index, previousState) in previousStates {
                transitionRatingCount(
                    from: previousState,
                    to: items[index].ratingState
                )
            }
            restoreCurrentFile(
                fileID: previousFileID,
                fallbackIndex: currentIndex
            )
            scheduleSave()
        case .cleanUp(
            let removed,
            let previousItemID,
            let previousIndex
        ):
            undoCleanUp(
                removed,
                previousItemID: previousItemID,
                previousIndex: previousIndex
            )
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
            return cleanUpCandidates.filter {
                !items[$0].hasMixedRatings && items[$0].rating != .yes
            }
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
            return cleanUpCandidatesContain {
                !items[$0].hasMixedRatings && items[$0].rating != .yes
            }
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
        guard !isFileOperationRunning else { return }
        flushPendingFilter()
        pendingCleanUp = mode
    }

    /// Moves every photo the mode rejects within the chosen scope to the
    /// macOS Trash — never a permanent delete. One ⌘Z brings the whole batch
    /// back. A photo is only removed if *all* its files could be trashed; on a
    /// partial failure its already-trashed files are put back. If that
    /// rollback also fails, the app reports the inconsistent pair explicitly.
    func performCleanUp(_ mode: CleanUpMode) {
        guard !isFileOperationRunning else { return }
        flushPendingFilter()
        // Resolve targets first — .selection reads the live selection —
        // then drop it: indices are about to shift.
        let targets = cleanUpTargets(for: mode)
        let snapshots = targets.compactMap { index in
            items.indices.contains(index) ? CleanUpPhotoSnapshot(index: index, item: items[index]) : nil
        }
        guard !snapshots.isEmpty else { return }
        let previousIndex = currentIndex
        let previousItemID = currentItemID
        cleanUpGeneration &+= 1
        let generation = cleanUpGeneration
        pendingCleanUp = nil
        setSelectionIndices([])
        activeFileOperation = .cleanUp
        let total = snapshots.reduce(0) { $0 + $1.item.allURLs.count }
        cleanUpProgress = CleanUpProgress(action: .movingToTrash, done: 0, total: total)
        let progressReporter = makeCleanUpProgressReporter(action: .movingToTrash, generation: generation)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CleanUpWorker.moveToTrash(snapshots, progress: progressReporter)
            await self?.finishCleanUp(
                result,
                previousItemID: previousItemID,
                previousIndex: previousIndex,
                generation: generation
            )
        }
    }

    private func finishCleanUp(
        _ result: TrashBatchResult,
        previousItemID: String?,
        previousIndex: Int,
        generation: UInt64
    ) {
        guard generation == cleanUpGeneration, isCleaningUp else { return }
        if result.requiresRecovery {
            activeFileOperation = nil
            cleanUpProgress = nil
            beginInterruptedOperationRecovery(rescanOnSuccess: true)
            return
        }
        let removed = result.succeeded.map {
            RemovedPhoto(index: $0.index, item: $0.item, trashedFiles: $0.files)
        }
        if !removed.isEmpty {
            let removedIndices = Set(removed.map(\.index))
            items = items.enumerated().filter { !removedIndices.contains($0.offset) }.map(\.element)
            let removedBefore = removed.filter { $0.index < previousIndex }.count
            rebuildDerivedData()
            restoreCurrentItem(
                itemID: previousItemID,
                fallbackIndex: previousIndex - removedBefore
            )
            pushUndo(.cleanUp(
                removed,
                previousItemID: previousItemID,
                previousIndex: previousIndex
            ))
            if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
            saveDebounce?.cancel()
            saveSession()
        }
        activeFileOperation = nil
        cleanUpProgress = nil
        if result.failedPhotos > 0 {
            var message: String
            if result.inconsistentPhotos > 0 {
                message = "\(result.failedPhotos) item\(result.failedPhotos == 1 ? "" : "s") couldn't be moved completely. "
                    + "For \(result.inconsistentPhotos), rollback also failed; check both the source folder and Trash."
            } else {
                message = result.failedPhotos == 1
                    ? "1 item couldn't be moved to the Trash and stayed in the folder."
                    : "\(result.failedPhotos) items couldn't be moved to the Trash and stayed in the folder."
            }
            if result.journalFailure {
                message += " Louppe stopped before another file was touched because its safety checkpoint couldn't be saved."
            }
            cleanUpError = message
        }
    }

    /// Brings a cleaned-up batch back: moves each file out of the Trash and
    /// reinserts the photos at their original positions (ascending index
    /// order, so every photo lands exactly where it was).
    private func undoCleanUp(
        _ removed: [RemovedPhoto],
        previousItemID: String?,
        previousIndex: Int
    ) {
        guard !isFileOperationRunning else { return }
        let snapshots = removed.map {
            TrashedPhotoSnapshot(index: $0.index, item: $0.item, files: $0.trashedFiles)
        }
        cleanUpGeneration &+= 1
        let generation = cleanUpGeneration
        activeFileOperation = .cleanUp
        let total = snapshots.reduce(0) { $0 + $1.files.count }
        cleanUpProgress = CleanUpProgress(action: .restoring, done: 0, total: total)
        let progressReporter = makeCleanUpProgressReporter(action: .restoring, generation: generation)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CleanUpWorker.restore(snapshots, progress: progressReporter)
            await self?.finishUndoCleanUp(
                result,
                allRemovedIndices: Set(removed.map(\.index)),
                previousItemID: previousItemID,
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
        previousItemID: String?,
        previousIndex: Int,
        generation: UInt64
    ) {
        guard generation == cleanUpGeneration, isCleaningUp else { return }
        if result.requiresRecovery {
            activeFileOperation = nil
            cleanUpProgress = nil
            beginInterruptedOperationRecovery(rescanOnSuccess: true)
            return
        }
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
                ? "1 item couldn't be restored from the Trash — it may have been deleted there."
                : "\(result.lostPhotos) items couldn't be restored from the Trash — they may have been deleted there."
            if result.inconsistentPhotos > 0 {
                cleanUpError? += " For \(result.inconsistentPhotos), rollback also failed; check both the source folder and Trash."
            }
            if result.journalFailure {
                cleanUpError? += " Louppe stopped before another file was touched because its safety checkpoint couldn't be saved."
            }
        }
        rebuildDerivedData()
        restoreCurrentItem(
            itemID: previousItemID,
            fallbackIndex: previousIndex
        )
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        saveDebounce?.cancel()
        saveSession()
        activeFileOperation = nil
        cleanUpProgress = nil
    }

    // MARK: - Export

    /// The folder the export started from. Completion refuses to apply moved
    /// IDs to a different session even though the active-operation guards
    /// already prevent folder replacement.
    private var activeExportFolder: URL?

    /// Raises the shared file-operation state before Copy or Move touches the
    /// destination. Copy now receives the same Quit/update/folder-switch
    /// protection as operations that move originals.
    func exportWillStart(mode: ExportMode) -> Bool {
        guard !isFileOperationRunning else { return false }
        activeFileOperation = mode == .copy ? .exportCopy : .exportMove
        activeExportFolder = sourceFolder
        return true
    }

    /// Clears the export state and, for Move, drops photos whose files fully
    /// transferred. A Move is not undoable: its files are gone from the
    /// source folder, so the undo stack is cleared.
    func finishExport(
        mode: ExportMode,
        movedIDs: [String],
        requiresRecovery: Bool
    ) {
        let expectedOperation: FileOperationKind = mode == .copy ? .exportCopy : .exportMove
        guard activeFileOperation == expectedOperation else { return }
        let expectedFolder = activeExportFolder
        activeExportFolder = nil
        activeFileOperation = nil
        if requiresRecovery {
            beginInterruptedOperationRecovery(rescanOnSuccess: true)
            return
        }
        guard mode == .move, !movedIDs.isEmpty else { return }
        // Belt over braces: the in-flight guards make a mid-move session swap
        // impossible, but never remove ids from an unrelated session.
        if let expectedFolder,
           sourceFolder?.standardizedFileURL != expectedFolder.standardizedFileURL {
            return
        }
        let ids = Set(movedIDs)
        let previousIndex = currentIndex
        let previousItemID = currentItemID
        let removedBefore = items.prefix(min(previousIndex, items.count)).filter { ids.contains($0.id) }.count
        setSelectionIndices([])
        items = items.filter { !ids.contains($0.id) }
        undoStack.removeAll()
        rebuildDerivedData()
        restoreCurrentItem(
            itemID: previousItemID,
            fallbackIndex: previousIndex - removedBefore
        )
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        saveDebounce?.cancel()
        saveSession()
    }

    // MARK: - Navigation (moves through *visible* photos only)

    func goNext() { stepVisible(1) }
    func goPrevious() { stepVisible(-1) }

    /// Moves to the photo in the same grid column on the row above or below.
    /// Each group starts a new grid, so crossing a group boundary lands in
    /// the nearest matching column of the adjacent group's first/last row.
    func goVertical(_ delta: Int) {
        guard !visibleGroups.isEmpty else { return }
        guard let location = preparedIndex.location(forItemIndex: currentIndex) else {
            setIndex(visibleIndices[0])
            return
        }
        let groupIndex = location.groupIndex
        let group = visibleGroups[groupIndex].indices
        let position = location.positionInGroup

        let columns = max(gridColumnCount, 1)
        let row = position / columns
        let column = position % columns
        let target: Int?

        if delta < 0 {
            if row > 0 {
                target = group[min((row - 1) * columns + column, group.count - 1)]
            } else if groupIndex > 0 {
                let previous = visibleGroups[groupIndex - 1].indices
                let lastRowStart = (previous.count - 1) / columns * columns
                target = previous[min(lastRowStart + column, previous.count - 1)]
            } else {
                target = nil
            }
        } else if delta > 0 {
            let nextRowStart = (row + 1) * columns
            if nextRowStart < group.count {
                target = group[min(nextRowStart + column, group.count - 1)]
            } else if groupIndex + 1 < visibleGroups.count {
                let next = visibleGroups[groupIndex + 1].indices
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
        guard let pos = preparedIndex.location(forItemIndex: currentIndex)?.position else {
            setIndex(visibleIndices[0])
            return
        }
        let newPos = min(max(pos + delta, 0), visibleIndices.count - 1)
        setIndex(visibleIndices[newPos])
    }

    func setIndex(_ index: Int) {
        guard !isFileOperationRunning, !items.isEmpty else { return }
        // Plain navigation (click, arrow key) collapses any multi-selection.
        setSelectionIndices([])
        let clamped = min(max(index, 0), items.count - 1)
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        prefetchAroundCurrent()
    }

    private func advanceToNextUndecided() {
        guard !visibleIndices.isEmpty else { return }
        let pos = preparedIndex.location(forItemIndex: currentIndex)?.position ?? 0
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

    /// The Browser column exists only in the Gallery view, so its toolbar
    /// button and the Q hotkey both come through this guard — the Grid must
    /// not change the Gallery's layout invisibly.
    func toggleBrowser() {
        guard viewMode == .gallery else { return }
        showBrowser.toggle()
    }

    func toggleZoom(_ mode: ZoomMode) {
        if mode == .actual {
            // S defines one inspection run. Enter centered; pressing S again
            // returns to Fit and clears the position carried across photos.
            actualSizeViewport.reset()
        }
        zoomMode = (zoomMode == mode) ? .fit : mode
    }

    /// Gallery double-click enters 100% with the clicked image point under the
    /// viewport center. Unlike S, it deliberately does not reset to center.
    func zoomToActual(at position: NormalizedImagePosition) {
        actualSizeViewport.request(position: position)
        zoomMode = .actual
    }

    /// A second Gallery double-click leaves the saved inspection point intact
    /// but returns the presentation to Fit. S remains the centered reset.
    func zoomToFit() {
        zoomMode = .fit
    }

    @discardableResult
    func toggleClippingWarnings() -> Bool {
        guard canToggleClippingWarnings else { return false }
        showClippingWarnings.toggle()
        return true
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
        guard let pos = preparedIndex.location(forItemIndex: currentIndex)?.position else { return }
        let windowOffsets = [1, 2, 3, -1]
        let photos = windowOffsets.compactMap { offset -> PhotoItem? in
            let p = pos + offset
            guard visibleIndices.indices.contains(p) else { return nil }
            let item = items[visibleIndices[p]]
            return item.mediaKind == .photo && item.isSupported ? item : nil
        }
        // Collapse repeated navigation/filter updates into one neighbourhood
        // warm-up. The visible image itself still starts immediately.
        let work = DispatchWorkItem {
            ImagePipeline.shared.prefetchFullImages(items: photos)
            HighResolutionImagePipeline.shared.prefetchSources(items: photos)
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
        enqueuePersistenceSave(request)
    }

    /// Queue the newest snapshot and return only when it has reached either
    /// the folder sidecar or Louppe's Application Support backup. The app
    /// delegate uses this with AppKit's asynchronous termination handshake,
    /// so the main thread never blocks while a last-second rating is saved.
    func saveSessionForTermination() async -> SessionPersistence.SaveResult? {
        saveDebounce?.cancel()
        saveDebounce = nil
        if let request = makeSaveRequest() {
            let result = await enqueuePersistenceSave(request).value
            applyPersistenceResult(result, request: request)
            return result
        }

        // `closeSession` captures its snapshot before clearing UI state. If
        // Quit follows immediately, wait for that exact queued snapshot.
        if let task = pendingPersistenceTask,
           let request = pendingPersistenceRequest {
            let result = await task.value
            applyPersistenceResult(result, request: request)
            if result.canDiscardInMemoryState { return result }
            let retry = refreshedSaveRequest(from: request)
            let retried = await enqueuePersistenceSave(retry).value
            applyPersistenceResult(retried, request: retry)
            return retried
        }

        if let request = retrySaveRequest {
            let retry = refreshedSaveRequest(from: request)
            let result = await enqueuePersistenceSave(retry).value
            applyPersistenceResult(result, request: retry)
            return result
        }
        return nil
    }

    /// Retry the newest live snapshot, or the exact snapshot retained after a
    /// failed Close Session. Success clears the warning automatically.
    func retryPersistence() {
        saveDebounce?.cancel()
        saveDebounce = nil
        if let request = makeSaveRequest() {
            enqueuePersistenceSave(request)
        } else if let request = retrySaveRequest {
            enqueuePersistenceSave(refreshedSaveRequest(from: request))
        }
    }

    private struct SaveRequest: Sendable {
        let folder: URL
        let session: SessionFile
        let sequence: UInt64
    }

    @discardableResult
    private func enqueuePersistenceSave(
        _ request: SaveRequest
    ) -> Task<SessionPersistence.SaveResult, Never> {
        let task = Task.detached { [persistence] in
            await persistence.save(
                request.session,
                for: request.folder,
                sequence: request.sequence
            )
        }
        pendingPersistenceTask = task
        pendingPersistenceRequest = request
        Task { @MainActor [weak self] in
            let result = await task.value
            self?.applyPersistenceResult(result, request: request)
        }
        return task
    }

    private func applyPersistenceResult(
        _ result: SessionPersistence.SaveResult,
        request: SaveRequest
    ) {
        guard request.sequence >= latestReportedSaveSequence else { return }
        if let folder = sourceFolder,
           folder.standardizedFileURL != request.folder.standardizedFileURL {
            return
        }
        guard result != .superseded else { return }
        latestReportedSaveSequence = request.sequence

        switch result {
        case .savedToSidecar:
            retrySaveRequest = nil
            persistenceWarning = nil
        case .savedToBackup(let sidecarFailure):
            retrySaveRequest = request
            switch sidecarFailure {
            case .permissionDenied:
                persistenceWarning = "This folder is read-only. Your ratings are safe in Louppe's backup, "
                    + "but not beside the photos. Restore write access, then retry."
            case .outOfSpace:
                persistenceWarning = "The photo volume is out of space. Your ratings are safe in Louppe's backup, "
                    + "but not beside the photos. Free some space, then retry."
            case .volumeUnavailable:
                persistenceWarning = "The photo volume is unavailable. Your ratings are safe in Louppe's backup. "
                    + "Reconnect it, then retry."
            case .encoding, .other:
                persistenceWarning = "Your ratings are safe in Louppe's backup, but the folder session file "
                    + "couldn't be updated. Retry when the folder is available."
            }
        case .failed(let failure):
            retrySaveRequest = request
            if failure.sidecar == .outOfSpace || failure.backup == .outOfSpace {
                persistenceWarning = "Your latest ratings are not saved because the disk is full. "
                    + "Free some space and retry before closing Louppe."
            } else if failure.sidecar == .permissionDenied
                        && failure.backup == .permissionDenied {
                persistenceWarning = "Your latest ratings are not saved because Louppe cannot write to "
                    + "the folder or its backup location. Fix the permissions and retry."
            } else if failure.sidecar == .volumeUnavailable
                        && failure.backup == .volumeUnavailable {
                persistenceWarning = "Your latest ratings are not saved because the storage volume is unavailable. "
                    + "Reconnect it and retry before closing Louppe."
            } else {
                persistenceWarning = "Your latest ratings are not saved. Retry before closing Louppe."
            }
        case .superseded:
            break
        }
    }

    private func refreshedSaveRequest(from request: SaveRequest) -> SaveRequest {
        var session = request.session
        session.scannedAt = Date()
        saveSequence &+= 1
        return SaveRequest(
            folder: request.folder,
            session: session,
            sequence: saveSequence
        )
    }

    /// Capture value-semantic session data on the main actor, then let the
    /// persistence actor perform the expensive encoding and file I/O.
    private func makeSaveRequest() -> SaveRequest? {
        guard let folder = sourceFolder, case .ready = phase else { return nil }
        let session = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: folder.path,
            scannedAt: Date(),
            entries: items.flatMap { item in
                item.individualFiles.map { file in
                    let rating = file.ratingSnapshot
                    return SessionEntry(
                        filename: file.id,
                        pairedFilename: nil,
                        rating: rating.rating.rawValue,
                        ratedAt: rating.ratedAt
                    )
                }
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
        guard !isFileOperationRunning else { return }
        saveDebounce?.cancel()
        saveDebounce = nil
        if let request = makeSaveRequest() {
            isSessionTransitioning = true
            let task = enqueuePersistenceSave(request)
            Task { @MainActor [weak self] in
                let result = await task.value
                guard let self else { return }
                self.isSessionTransitioning = false
                guard result.canDiscardInMemoryState else { return }
                self.finishClosingSession()
            }
            return
        }
        finishClosingSession()
    }

    private func finishClosingSession() {
        videoPlayback.stop()
        zoomMode = .fit
        showClippingWarnings = false
        actualSizeViewport.reset()
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        cleanUpGeneration &+= 1
        filterDebounce?.cancel()
        filterDebounce = nil
        prefetchDebounce?.cancel()
        prefetchDebounce = nil
        scanResumeIdentity = nil
        items = []
        resetDerivedData()
        sourceFolder = nil
        undoStack = []
        setSelectionIndices([])
        isClearAllRatingsConfirmationPresented = false
        pendingCleanUp = nil
        cleanUpError = nil
        currentIndex = 0
        viewMode = .gallery
        filter = PhotoFilter()
        sort = PhotoSort()
        visibleIndices = []
        isFilterPresented = false
        isSortPresented = false
        isGroupingEnabled = true
        phase = .welcome
    }
}
