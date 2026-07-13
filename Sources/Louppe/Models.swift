import Foundation

enum Rating: String, Codable {
    case undecided
    case yes
    case no
}

struct PhotoItem: Identifiable {
    /// Relative path of the primary file within the source folder — stable session key.
    let id: String
    let primaryURL: URL
    let pairedURL: URL?
    let captureDate: Date?
    /// Camera + lens read once during the scan, so the filter search can
    /// match them without re-opening every file.
    let cameraModel: String?
    let lensModel: String?
    let fileSize: Int64
    var rating: Rating = .undecided
    var ratedAt: Date?

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
        if pairedURL != nil { return "RAW + JPEG" }
        if isRaw { return "RAW" }
        let ext = primaryURL.pathExtension.lowercased()
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

    /// Everything the filter's search box can match against.
    var searchableText: String {
        var parts = [displayName, fileTypeLabel]
        if let paired = pairedURL?.lastPathComponent { parts.append(paired) }
        if let cameraModel { parts.append(cameraModel) }
        if let lensModel { parts.append(lensModel) }
        if let captureDate { parts.append(Self.searchDateFormatter.string(from: captureDate)) }
        return parts.joined(separator: " ")
    }

    private static let searchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
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

    func matches(_ item: PhotoItem) -> Bool {
        if excludedTypes.contains(item.fileTypeLabel) { return false }
        if excludedCameras.contains(item.cameraLabel) { return false }
        if excludedLenses.contains(item.lensLabel) { return false }

        if dateEnabled {
            // Whole-day bounds, so from == to means "that one day".
            guard let date = item.captureDate else { return false }
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: dateFrom)
            guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dateTo)) else { return false }
            guard date >= start && date < end else { return false }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let haystack = item.searchableText
            for token in query.split(separator: " ") {
                guard haystack.localizedCaseInsensitiveContains(token) else { return false }
            }
        }
        return true
    }
}

// MARK: - Session sidecar file (.louppe_session.json)

struct SessionEntry: Codable {
    var filename: String
    var pairedFilename: String?
    var rating: String
    var ratedAt: Date?
}

struct SessionFile: Codable {
    var version: Int
    var sourcePath: String
    var scannedAt: Date
    var entries: [SessionEntry]
}

// MARK: - Metadata for the info panel

struct MetadataField: Identifiable {
    let id: String
    let label: String
    let value: String
}
