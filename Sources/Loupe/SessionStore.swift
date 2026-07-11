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
    @Published var scanError: String?
    @Published var recentFolders: [URL] = []

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

    nonisolated static let supportedExtensions: Set<String> = ["nef", "raf", "jpg", "jpeg", "tif", "tiff"]
    nonisolated static let rawExtensions: Set<String> = ["nef", "raf"]
    nonisolated static let maxScanDepth = 5
    nonisolated static let sidecarName = ".loupe_session.json"

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
        NSLog("Loupe: opening folder %@", url.path)
        sourceFolder = url
        scanError = nil
        phase = .scanning(found: 0)
        items = []
        undoStack = []
        addToRecents(url)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let scanned = try self.scanFolder(url) { count in
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
        NSLog("Loupe: scan finished, %d items", scanned.count)
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
        phase = loaded.isEmpty ? .welcome : .ready
        if loaded.isEmpty {
            scanError = "No supported photos (.NEF, .RAF, .JPG, .JPEG, .TIF) were found in that folder."
        } else {
            saveSession()
            prefetchAroundCurrent()
        }
    }

    // MARK: - Scanning (runs off the main thread)

    nonisolated private func scanFolder(_ root: URL, progress: @escaping (Int) -> Void) throws -> [PhotoItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw NSError(domain: "Loupe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read that folder."])
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > Self.maxScanDepth {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append(url)
            if files.count % 25 == 0 { progress(files.count) }
        }

        // Group RAW+JPEG pairs: same folder, same base filename.
        var groups: [String: [URL]] = [:]
        for url in files {
            let key = url.deletingPathExtension().path.lowercased()
            groups[key, default: []].append(url)
        }

        var result: [PhotoItem] = []
        let rootPath = root.standardizedFileURL.path
        for (_, urls) in groups {
            let raws = urls.filter { Self.rawExtensions.contains($0.pathExtension.lowercased()) }
            let jpegs = urls.filter { !Self.rawExtensions.contains($0.pathExtension.lowercased()) }

            var pairs: [(primary: URL, paired: URL?)] = []
            if let raw = raws.first, let jpeg = jpegs.first {
                pairs.append((raw, jpeg))
                // Rare leftovers (e.g., two RAWs with the same base name) become separate items.
                for extra in raws.dropFirst() { pairs.append((extra, nil)) }
                for extra in jpegs.dropFirst() { pairs.append((extra, nil)) }
            } else {
                for url in urls { pairs.append((url, nil)) }
            }

            for (primary, paired) in pairs {
                let size = (try? FileManager.default.attributesOfItem(atPath: primary.path)[.size] as? Int64) ?? 0
                let captureDate = MetadataExtractor.captureDate(for: primary)
                    ?? (try? primary.resourceValues(forKeys: [.creationDateKey]).creationDate)
                let relative = relativePath(of: primary, under: rootPath)
                result.append(PhotoItem(
                    id: relative,
                    primaryURL: primary,
                    pairedURL: paired,
                    captureDate: captureDate,
                    fileSize: size
                ))
            }
        }

        result.sort { a, b in
            switch (a.captureDate, b.captureDate) {
            case let (da?, db?) where da != db: return da < db
            case (nil, .some): return false
            case (.some, nil): return true
            default: return a.id.localizedStandardCompare(b.id) == .orderedAscending
            }
        }
        return result
    }

    nonisolated private func relativePath(of url: URL, under rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    // MARK: - Rating

    func rate(_ rating: Rating) {
        guard let item = currentItem else { return }
        setRating(rating, atIndex: currentIndex, recordUndo: true)
        _ = item
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

    // MARK: - Navigation

    func goNext() { setIndex(currentIndex + 1) }
    func goPrevious() { setIndex(currentIndex - 1) }

    func setIndex(_ index: Int) {
        guard !items.isEmpty else { return }
        let clamped = min(max(index, 0), items.count - 1)
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        prefetchAroundCurrent()
    }

    private func advanceToNextUndecided() {
        guard !items.isEmpty else { return }
        // Search forward from the current photo, wrapping around once.
        let count = items.count
        for offset in 1...count {
            let candidate = (currentIndex + offset) % count
            if items[candidate].rating == .undecided {
                currentIndex = candidate
                prefetchAroundCurrent()
                return
            }
        }
        // Nothing undecided left: just step forward if possible.
        setIndex(currentIndex + 1)
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

    /// Re-scan the current folder to pick up newly added photos.
    /// Existing ratings survive: they're saved to the sidecar first,
    /// and the scan restores them by filename.
    func rescan() {
        guard let folder = sourceFolder else { return }
        saveDebounce?.cancel()
        saveSession()
        openFolder(folder)
    }

    private func prefetchAroundCurrent() {
        let windowOffsets = [1, 2, 3, -1]
        let urls = windowOffsets.compactMap { offset -> URL? in
            let i = currentIndex + offset
            guard items.indices.contains(i) else { return nil }
            return items[i].primaryURL
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
        let dir = support.appendingPathComponent("Loupe/Sessions", isDirectory: true)
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
        phase = .welcome
    }
}
