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

    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || dateEnabled
            || !excludedTypes.isEmpty
    }

    func matches(_ item: PhotoItem) -> Bool {
        if excludedTypes.contains(item.fileTypeLabel) { return false }

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
