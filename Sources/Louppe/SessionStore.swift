import Foundation
import AppKit

enum ViewMode {
    case culling
    case lightTable
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
    @Published var viewMode: ViewMode = .culling
    @Published var showMetadataPanel = true
    @Published var showFilmstrip = true
    @Published var zoomMode: ZoomMode = .fit
    @Published var gridThumbSize: CGFloat = 170
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
        didSet { if filter != oldValue { applyFilter() } }
    }
    /// The toolbar sort menu. Reorders `visibleIndices` only — `items` keeps
    /// its scan order, so undo indices and the sidecar are unaffected.
    @Published var sort = PhotoSort() {
        didSet { if sort != oldValue { applyFilter() } }
    }
    /// Indices into `items` that pass the current filter, in the chosen sort order.
    @Published private(set) var visibleIndices: [Int] = []

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
    private struct RemovedPhoto {
        let index: Int
        let item: PhotoItem
        let trashedFiles: [(original: URL, trash: URL)]
    }
    private enum UndoStep {
        case ratings([RatingChange], previousIndex: Int)
        case cleanUp([RemovedPhoto], previousIndex: Int)
    }
    private var undoStack: [UndoStep] = []
    private var saveDebounce: DispatchWorkItem?

    nonisolated static let sidecarName = ".louppe_session.json"

    init() {
        loadRecents()
    }

    // MARK: - Counts

    var yesCount: Int { items.filter { $0.rating == .yes }.count }
    var noCount: Int { items.filter { $0.rating == .no }.count }
    var undecidedCount: Int { items.filter { $0.rating == .undecided }.count }

    var currentItem: PhotoItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    // MARK: - Filtering

    /// The photos the views should show, each with its absolute index into `items`.
    /// Defensive bounds check: even if an index momentarily goes stale while
    /// `items` is being replaced, render fewer tiles instead of crashing.
    var visibleItems: [(index: Int, item: PhotoItem)] {
        visibleIndices.compactMap { i in
            items.indices.contains(i) ? (i, items[i]) : nil
        }
    }

    /// Distinct file-type labels present in this session, for the filter menu.
    var availableTypes: [String] {
        Set(items.map(\.fileTypeLabel)).sorted()
    }

    /// Distinct camera / lens labels in this session, for the filter menu.
    var availableCameras: [String] {
        Set(items.map(\.cameraLabel)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var availableLenses: [String] {
        Set(items.map(\.lensLabel)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Span of capture dates in this session — seeds the filter's date pickers.
    var captureDateRange: ClosedRange<Date>? {
        let dates = items.compactMap(\.captureDate)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first...last
    }

    private func applyFilter() {
        visibleIndices = items.indices
            .filter { filter.matches(items[$0]) }
            .sorted { sort.areInOrder(items[$0], items[$1]) }
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

    /// True when the photo at visible position `pos` was taken on a different
    /// day than the visible one before it — the filmstrip and light table
    /// draw a separator there.
    func startsNewDay(atVisiblePosition pos: Int) -> Bool {
        // Day separators only make sense while photos are in date order —
        // sorted by name, neighbours can hop between days arbitrarily.
        guard sort.key == .captureDate else { return false }
        guard pos > 0, visibleIndices.indices.contains(pos),
              items.indices.contains(visibleIndices[pos - 1]),
              items.indices.contains(visibleIndices[pos]) else { return false }
        guard let previous = items[visibleIndices[pos - 1]].captureDate,
              let current = items[visibleIndices[pos]].captureDate else { return false }
        return !Calendar.current.isDate(previous, inSameDayAs: current)
    }

    // MARK: - Opening a folder

    func promptForSourceFolder() {
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
        sourceFolder = url
        scanError = nil
        phase = .scanning(found: 0)
        // visibleIndices must be cleared in the same turn items is emptied —
        // stale indices into a shrunk array crash any view that renders first.
        visibleIndices = []
        selectedIndices = []
        items = []
        undoStack = []
        pendingCleanUp = nil
        addToRecents(url)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let scanned = try FolderScanner.scan(url) { count in
                    Task { @MainActor in
                        if case .scanning = self.phase {
                            self.phase = .scanning(found: count)
                        }
                    }
                }
                await MainActor.run {
                    self.finishScan(url: url, scanned: scanned)
                }
            } catch {
                await MainActor.run {
                    self.scanError = error.localizedDescription
                    self.phase = .welcome
                }
            }
        }
    }

    private func finishScan(url: URL, scanned: [PhotoItem]) {
        var loaded = scanned
        // Restore prior ratings from the sidecar file, if present.
        if let session = readSessionFile(for: url) {
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
        // Resume from the first undecided photo.
        currentIndex = loaded.firstIndex(where: { $0.rating == .undecided }) ?? 0
        // Recompute visibility (a re-scan keeps the active filter; it may
        // also snap currentIndex onto a visible photo).
        applyFilter()
        phase = loaded.isEmpty ? .welcome : .ready
        if loaded.isEmpty {
            scanError = "No supported photos (.NEF, .RAF, .JPG, .JPEG, .TIF) were found in that folder."
        } else {
            saveSession()
            prefetchAroundCurrent()
        }
    }

    /// Re-scan the current folder to pick up newly added photos.
    /// Existing ratings survive: they're saved to the sidecar first,
    /// and the scan restores them by filename.
    func rescan() {
        guard let folder = sourceFolder else { return }
        saveDebounce?.cancel()
        saveSession()
        openFolder(folder)
    }

    // MARK: - Multi-selection

    /// What a rating (F/D) applies to: the multi-selection when one is
    /// active, otherwise just the current photo.
    var effectiveSelection: Set<Int> {
        if !selectedIndices.isEmpty { return selectedIndices }
        return items.indices.contains(currentIndex) ? [currentIndex] : []
    }

    func clearSelection() {
        selectedIndices = []
    }

    /// Routes a thumbnail click by modifier key — shared by the filmstrip and
    /// the light table so both respond identically. `plainClick` runs when no
    /// modifier is held (the filmstrip jumps; the light table cycles rating).
    func handleThumbnailClick(at index: Int, plainClick: () -> Void) {
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
        guard let target = visibleIndices.firstIndex(of: index) else { return }
        let anchor = visibleIndices.firstIndex(of: currentIndex) ?? target
        selectedIndices = Set(visibleIndices[min(anchor, target)...max(anchor, target)])
    }

    /// ⌘-click: add or remove a single photo.
    func toggleSelection(of index: Int) {
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
        guard let pos = visibleIndices.firstIndex(of: currentIndex) else { return }
        selectedIndices = Set(forward ? visibleIndices[pos...] : visibleIndices[...pos])
    }

    /// ⌘A: select every photo that passes the current filter.
    func selectAllVisible() {
        selectedIndices = Set(visibleIndices)
    }

    /// Rubber-band drag in the light table: the selection follows the
    /// rectangle live. `currentIndex` is deliberately left alone here —
    /// moving it mid-drag would auto-scroll the grid under the cursor.
    func setSelection(_ indices: Set<Int>) {
        let valid = indices.filter { items.indices.contains($0) }
        // Called on every drag tick; skip the publish (and the grid/toolbar
        // rebuilds it triggers) when the hit-tested set hasn't changed.
        guard valid != selectedIndices else { return }
        selectedIndices = valid
    }

    /// After a rubber-band drag ends, park the current photo on a selected
    /// one so the keyboard rates what the user just outlined.
    func commitSelectionAnchor() {
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
        applyRating(rating, to: effectiveSelection.sorted())
        selectedIndices = []
        advanceToNextUndecided()
    }

    /// Light-table click: cycle the clicked photo's rating. Clicking a photo
    /// that's part of a multi-selection gives the whole selection the clicked
    /// photo's next rating in one undoable step; the selection stays so the
    /// user can keep cycling.
    func toggleRating(at index: Int) {
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
        items[index].rating = rating
        items[index].ratedAt = Date()
        scheduleSave()
    }

    /// Reset every photo to undecided — one undo step brings all ratings back.
    func clearAllRatings() {
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
        scheduleSave()
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
        guard let step = undoStack.popLast() else { return }
        // Undo moves the session back in time; a live selection would no
        // longer mean what the user built it for.
        selectedIndices = []
        switch step {
        case .ratings(let changes, let previousIndex):
            for change in changes where items.indices.contains(change.index) {
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
    /// When true (the default) and a filter is active, Clean Up only
    /// considers the photos the filter currently shows — hidden photos stay
    /// untouched. Off means the whole folder is considered.
    @Published var cleanUpFilteredOnly = true

    /// Whether the next clean-up is actually limited to the filtered photos
    /// (the toggle only matters while a filter is active).
    var cleanUpScopeIsFiltered: Bool { cleanUpFilteredOnly && filter.isActive }

    /// The photos a rating-based clean-up would consider, per the scope
    /// toggle. Order doesn't matter downstream (undo re-sorts by index), so
    /// no sort here — `visibleIndices` is reused as-is.
    private var cleanUpCandidates: [Int] {
        cleanUpScopeIsFiltered ? visibleIndices : Array(items.indices)
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
            return cleanUpCandidates.contains { items[$0].rating == .no }
        case .keepOnlyYes:
            return cleanUpCandidates.contains { items[$0].rating != .yes }
        }
    }

    /// How many photos (and actual files, counting RAW+JPEG pairs as two)
    /// a clean-up mode would move to the Trash, respecting the scope toggle.
    /// Only needed once, when the confirmation dialog opens.
    func cleanUpCounts(for mode: CleanUpMode) -> (photos: Int, files: Int) {
        let doomed = cleanUpTargets(for: mode).map { items[$0] }
        return (doomed.count, doomed.reduce(0) { $0 + $1.allURLs.count })
    }

    /// Menu label for trashing the selection, with a live count. Lives on the
    /// store so the toolbar menu and the File menu share one source of truth.
    var selectionCleanUpTitle: String {
        let count = effectiveSelection.count
        return count > 1 ? "Move \(count) Selected to Trash…" : "Move Selected to Trash…"
    }

    /// Moves every photo the mode rejects (within the scope the toggle
    /// chose: filtered photos only, or the whole folder) to the macOS Trash
    /// — never a permanent delete. One ⌘Z brings the whole batch back. A
    /// photo is only removed if *all* its files could be trashed; on a
    /// partial failure its already-trashed files are put back so RAW+JPEG
    /// pairs stay together.
    func performCleanUp(_ mode: CleanUpMode) {
        // Resolve targets first — .selection reads the live selection —
        // then drop it: indices are about to shift.
        let targets = cleanUpTargets(for: mode)
        selectedIndices = []
        let fm = FileManager.default
        var removed: [RemovedPhoto] = []
        var failedPhotos = 0

        for index in targets where items.indices.contains(index) {
            var trashed: [(original: URL, trash: URL)] = []
            var failed = false
            for url in items[index].allURLs {
                var trashURL: NSURL?
                try? fm.trashItem(at: url, resultingItemURL: &trashURL)
                guard let landed = trashURL as URL? else { failed = true; break }
                trashed.append((url, landed))
            }
            if failed {
                for (original, trash) in trashed.reversed() {
                    try? fm.moveItem(at: trash, to: original)
                }
                failedPhotos += 1
            } else {
                removed.append(RemovedPhoto(index: index, item: items[index], trashedFiles: trashed))
            }
        }

        if !removed.isEmpty {
            let previousIndex = currentIndex
            let removedIndices = Set(removed.map(\.index))
            items = items.enumerated().filter { !removedIndices.contains($0.offset) }.map(\.element)
            // The photo that was selected keeps its place: its new index is the
            // old one minus however many removed photos sat before it.
            let removedBefore = removed.filter { $0.index < previousIndex }.count
            currentIndex = min(max(previousIndex - removedBefore, 0), max(items.count - 1, 0))
            pushUndo(.cleanUp(removed, previousIndex: previousIndex))
            applyFilter()
            // Files just left the folder — update the sidecar right away,
            // not after the usual debounce.
            saveDebounce?.cancel()
            saveSession()
        }

        if failedPhotos > 0 {
            cleanUpError = failedPhotos == 1
                ? "1 photo couldn't be moved to the Trash and stayed in the folder."
                : "\(failedPhotos) photos couldn't be moved to the Trash and stayed in the folder."
        }
    }

    /// Brings a cleaned-up batch back: moves each file out of the Trash and
    /// reinserts the photos at their original positions (ascending index
    /// order, so every photo lands exactly where it was).
    private func undoCleanUp(_ removed: [RemovedPhoto], previousIndex: Int) {
        let fm = FileManager.default
        var lost = 0
        for photo in removed.sorted(by: { $0.index < $1.index }) {
            var restored: [(original: URL, trash: URL)] = []
            var failed = false
            for (original, trash) in photo.trashedFiles {
                do {
                    try fm.moveItem(at: trash, to: original)
                    restored.append((original, trash))
                } catch {
                    failed = true
                    break
                }
            }
            if failed {
                // Re-trash what did come back, so the photo isn't half-restored.
                for (original, trash) in restored.reversed() {
                    try? fm.moveItem(at: original, to: trash)
                }
                lost += 1
            } else {
                items.insert(photo.item, at: min(photo.index, items.count))
            }
        }
        if lost > 0 {
            // Some photos are gone for good (Trash emptied?). Older undo steps'
            // indices no longer line up with `items`, so drop them rather than
            // risk restoring a rating onto the wrong photo.
            undoStack.removeAll()
            cleanUpError = lost == 1
                ? "1 photo couldn't be restored from the Trash — it may have been deleted there."
                : "\(lost) photos couldn't be restored from the Trash — they may have been deleted there."
        }
        if !items.isEmpty {
            currentIndex = min(max(previousIndex, 0), items.count - 1)
        }
        applyFilter()
        saveDebounce?.cancel()
        saveSession()
    }

    // MARK: - Navigation (moves through *visible* photos only)

    func goNext() { stepVisible(1) }
    func goPrevious() { stepVisible(-1) }

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
        guard !items.isEmpty else { return }
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
        viewMode = (viewMode == .culling) ? .lightTable : .culling
    }

    func toggleZoom(_ mode: ZoomMode) {
        zoomMode = (zoomMode == mode) ? .fit : mode
    }

    /// ⌘+ / ⌘− in the light table: bigger thumbnails mean fewer per row.
    func zoomGrid(larger: Bool) {
        let next = larger ? gridThumbSize * 1.25 : gridThumbSize / 1.25
        gridThumbSize = min(max(next, 90), 400)
    }

    private func prefetchAroundCurrent() {
        // Prefetch the neighbouring *visible* photos, so filtered-out files
        // in between don't waste the warm-up window.
        guard let pos = visibleIndices.firstIndex(of: currentIndex) else { return }
        let windowOffsets = [1, 2, 3, -1]
        let urls = windowOffsets.compactMap { offset -> URL? in
            let p = pos + offset
            guard visibleIndices.indices.contains(p) else { return nil }
            let item = items[visibleIndices[p]]
            return item.isSupported ? item.primaryURL : nil
        }
        ImagePipeline.shared.prefetchFullImages(urls: urls)
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
        guard let folder = sourceFolder, !items.isEmpty else { return }
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }

        // Prefer a sidecar in the source folder; fall back to Application Support
        // when the volume is read-only (e.g., a locked SD card).
        let sidecar = folder.appendingPathComponent(Self.sidecarName)
        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            try? data.write(to: fallbackSessionURL(for: folder), options: .atomic)
        }
    }

    private func readSessionFile(for folder: URL) -> SessionFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = folder.appendingPathComponent(Self.sidecarName)
        if let data = try? Data(contentsOf: sidecar),
           let session = try? decoder.decode(SessionFile.self, from: data) {
            return session
        }
        if let data = try? Data(contentsOf: fallbackSessionURL(for: folder)),
           let session = try? decoder.decode(SessionFile.self, from: data) {
            return session
        }
        return nil
    }

    private func fallbackSessionURL(for folder: URL) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Louppe/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var hash: UInt64 = 14695981039346656037
        for byte in folder.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return dir.appendingPathComponent(String(format: "%016llx.json", hash))
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
        saveDebounce?.cancel()
        saveSession()
        items = []
        sourceFolder = nil
        undoStack = []
        selectedIndices = []
        pendingCleanUp = nil
        cleanUpError = nil
        currentIndex = 0
        viewMode = .culling
        filter = PhotoFilter()
        sort = PhotoSort()
        visibleIndices = []
        isFilterPresented = false
        phase = .welcome
    }
}
