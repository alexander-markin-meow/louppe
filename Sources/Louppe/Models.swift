import Foundation

enum SessionConstants {
    static let sidecarName = ".louppe_session.json"
}

enum Rating: String, Codable, Sendable {
    case undecided
    case yes
    case no
}

struct PhotoItem: Identifiable, Sendable {
    /// Relative path of the primary file within the source folder — stable session key.
    let id: String
    let primaryURL: URL
    let pairedURL: URL?
    let captureDate: Date?
    /// Camera + lens read once during the scan, so the filter search can
    /// match them without re-opening every file.
    let cameraModel: String?
    let lensModel: String?
    /// Captured during the folder scan and reused by the image cache. Keeping
    /// it on the item avoids a synchronous filesystem lookup whenever a lazy
    /// thumbnail cell is recreated while scrolling.
    let primaryModificationDate: Date?
    let fileSize: Int64
    let pairedFileSize: Int64
    /// Locale-folded metadata assembled once during scanning. Search filtering
    /// reads this string directly instead of rebuilding and date-formatting it
    /// for every photo on every keystroke.
    let searchableText: String
    var rating: Rating = .undecided
    var ratedAt: Date?

    init(
        id: String,
        primaryURL: URL,
        pairedURL: URL?,
        captureDate: Date?,
        cameraModel: String?,
        lensModel: String?,
        primaryModificationDate: Date? = nil,
        fileSize: Int64,
        pairedFileSize: Int64 = 0,
        rating: Rating = .undecided,
        ratedAt: Date? = nil
    ) {
        self.id = id
        self.primaryURL = primaryURL
        self.pairedURL = pairedURL
        self.captureDate = captureDate
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.primaryModificationDate = primaryModificationDate
        self.fileSize = fileSize
        self.pairedFileSize = pairedFileSize
        self.rating = rating
        self.ratedAt = ratedAt

        var parts = [primaryURL.lastPathComponent, Self.fileTypeLabel(primaryURL: primaryURL, pairedURL: pairedURL)]
        if let paired = pairedURL?.lastPathComponent { parts.append(paired) }
        if let cameraModel { parts.append(cameraModel) }
        if let lensModel { parts.append(lensModel) }
        if let captureDate { parts.append(Self.searchDateFormatter.string(from: captureDate)) }
        searchableText = Self.normalizeForSearch(parts.joined(separator: " "))
    }

    var displayName: String { primaryURL.lastPathComponent }

    var isRaw: Bool {
        FolderScanner.rawExtensions.contains(primaryURL.pathExtension.lowercased())
    }

    /// Whether we can actually decode and preview this file. Unsupported visual
    /// files still appear in the session, just as a placeholder tile.
    var isSupported: Bool {
        FolderScanner.supportedExtensions.contains(primaryURL.pathExtension.lowercased())
    }

    var fileTypeLabel: String {
        Self.fileTypeLabel(primaryURL: primaryURL, pairedURL: pairedURL)
    }

    private static func fileTypeLabel(primaryURL: URL, pairedURL: URL?) -> String {
        if pairedURL != nil { return "RAW + JPEG" }
        let ext = primaryURL.pathExtension.lowercased()
        if FolderScanner.rawExtensions.contains(ext) { return "RAW" }
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "tif", "tiff": return "TIFF"
        default: return ext.uppercased()
        }
    }

    /// Labels the camera/lens filter toggles group by. Files without EXIF
    /// (screenshots, videos…) collect under "Unknown" so they stay filterable.
    var cameraLabel: String { cameraModel ?? "Unknown" }
    var lensLabel: String { lensModel ?? "Unknown" }

    var allURLs: [URL] {
        var urls = [primaryURL]
        if let paired = pairedURL { urls.append(paired) }
        return urls
    }

    var totalFileSize: Int64 { fileSize + pairedFileSize }

    static func normalizeForSearch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static let searchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Clean up

/// The clean-up actions. All of them move files to the macOS Trash — never a
/// permanent delete — so they're recoverable with ⌘Z or from the Trash itself.
/// Which photos each mode targets is decided in `SessionStore.cleanUpTargets`.
enum CleanUpMode: Sendable {
    /// Trash the currently selected photo(s).
    case selection
    /// Trash the photos marked No; Yes and unrated photos stay in the folder.
    case trashNo
    /// Keep only the photos marked Yes; everything else is trashed.
    case keepOnlyYes
}

// MARK: - Session sort

/// How the toolbar sort menu orders the visible photos.
struct PhotoSort: Equatable {
    enum Key: Equatable {
        case captureDate
        case name
    }
    var key: Key = .captureDate
    var ascending = true

    /// Comparator for the session's visible order. Photos without a capture
    /// date always sort to the end, whichever direction is chosen.
    func areInOrder(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        switch key {
        case .captureDate:
            switch (a.captureDate, b.captureDate) {
            case let (da?, db?) where da != db:
                return ascending ? da < db : da > db
            case (nil, .some): return false
            case (.some, nil): return true
            default: return namesInOrder(a, b)
            }
        case .name:
            return namesInOrder(a, b)
        }
    }

    /// Finder-style name comparison (numbers compare numerically, so
    /// IMG_9 comes before IMG_10). Ties break on the stable id.
    private func namesInOrder(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        let comparison = a.displayName.localizedStandardCompare(b.displayName)
        if comparison != .orderedSame {
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return a.id < b.id
    }
}

// MARK: - Session filter

/// What the toolbar filter menu narrows the session down to.
/// An inactive filter shows everything.
struct PhotoFilter: Equatable {
    var searchText = ""
    var dateEnabled = false
    var dateFrom = Date()
    var dateTo = Date()
    /// File-type labels the user has switched off. Empty = all types shown,
    /// so newly appearing types after a re-scan default to visible.
    var excludedTypes: Set<String> = []
    /// Same exclusion pattern for camera and lens labels.
    var excludedCameras: Set<String> = []
    var excludedLenses: Set<String> = []

    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || dateEnabled
            || !excludedTypes.isEmpty
            || !excludedCameras.isEmpty
            || !excludedLenses.isEmpty
    }

}

/// Expensive, filter-wide work (date bounds and query normalization) is done
/// once before walking the photo list.
struct PreparedPhotoFilter {
    let excludedTypes: Set<String>
    let excludedCameras: Set<String>
    let excludedLenses: Set<String>
    let dateRange: Range<Date>?
    let searchTokens: [Substring]

    init(_ filter: PhotoFilter, calendar: Calendar = .current) {
        excludedTypes = filter.excludedTypes
        excludedCameras = filter.excludedCameras
        excludedLenses = filter.excludedLenses
        if filter.dateEnabled,
           let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: filter.dateTo)) {
            dateRange = calendar.startOfDay(for: filter.dateFrom)..<end
        } else {
            dateRange = nil
        }
        let query = PhotoItem.normalizeForSearch(filter.searchText.trimmingCharacters(in: .whitespaces))
        searchTokens = query.split(whereSeparator: \.isWhitespace)
    }

    func matches(_ item: PhotoItem) -> Bool {
        if excludedTypes.contains(item.fileTypeLabel) { return false }
        if excludedCameras.contains(item.cameraLabel) { return false }
        if excludedLenses.contains(item.lensLabel) { return false }
        if let dateRange {
            guard let date = item.captureDate, dateRange.contains(date) else { return false }
        }
        for token in searchTokens where !item.searchableText.contains(token) {
            return false
        }
        return true
    }
}

// MARK: - Session sidecar file (.louppe_session.json)

struct SessionEntry: Codable, Sendable {
    var filename: String
    var pairedFilename: String?
    var rating: String
    var ratedAt: Date?
}

struct SessionFile: Codable, Sendable {
    var version: Int
    var sourcePath: String
    var scannedAt: Date
    var entries: [SessionEntry]
}

struct CleanUpProgress: Sendable {
    enum Action: Sendable {
        case movingToTrash
        case restoring
    }
    let action: Action
    let done: Int
    let total: Int

    var title: String {
        switch action {
        case .movingToTrash: return "Moving files to the Trash…"
        case .restoring: return "Restoring files from the Trash…"
        }
    }
}

// MARK: - Metadata for the info panel

struct MetadataField: Identifiable {
    let id: String
    let label: String
    let value: String
}
