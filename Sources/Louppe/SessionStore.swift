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

    private(set) var sourceFolder: URL?

    /// One undo step can hold several photo changes (e.g. "clear all"),
    /// so a single ⌘Z restores the whole batch.
    private struct RatingChange {
        let index: Int
        let previousRating: Rating
        let previousRatedAt: Date?
    }
    private var undoStack: [(changes: [RatingChange], previousIndex: Int)] = []
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
        items = []
        undoStack = []
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

    // MARK: - Rating

    func rate(_ rating: Rating) {
        setRating(rating, atIndex: currentIndex, recordUndo: true)
        advanceToNextUndecided()
    }

    func toggleRating(at index: Int) {
        guard items.indices.contains(index) else { return }
        let next: Rating
        switch items[index].rating {
        case .undecided: next = .yes
        case .yes: next = .no
        case .no: next = .undecided
        }
        setRating(next, atIndex: index, recordUndo: true)
    }

    private func setRating(_ rating: Rating, atIndex index: Int, recordUndo: Bool) {
        guard items.indices.contains(index) else { return }
        if recordUndo {
            let change = RatingChange(index: index, previousRating: items[index].rating, previousRatedAt: items[index].ratedAt)
            undoStack.append(([change], currentIndex))
            if undoStack.count > 500 { undoStack.removeFirst() }
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
        undoStack.append((changes, currentIndex))
        for i in items.indices {
            items[i].rating = .undecided
            items[i].ratedAt = nil
        }
        scheduleSave()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        for change in last.changes where items.indices.contains(change.index) {
            items[change.index].rating = change.previousRating
            items[change.index].ratedAt = change.previousRatedAt
        }
        if !items.isEmpty {
            currentIndex = min(max(last.previousIndex, 0), items.count - 1)
        }
        scheduleSave()
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
        currentIndex = 0
        viewMode = .culling
        filter = PhotoFilter()
        sort = PhotoSort()
        visibleIndices = []
        isFilterPresented = false
        phase = .welcome
    }
}
