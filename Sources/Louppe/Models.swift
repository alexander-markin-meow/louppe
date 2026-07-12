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
    let fileSize: Int64
    var rating: Rating = .undecided
    var ratedAt: Date?

    var displayName: String { primaryURL.lastPathComponent }

    var isRaw: Bool {
        ["nef", "raf"].contains(primaryURL.pathExtension.lowercased())
    }

    var fileTypeLabel: String {
        if pairedURL != nil { return "RAW + JPEG" }
        if isRaw { return "RAW" }
        switch primaryURL.pathExtension.lowercased() {
        case "tif", "tiff": return "TIFF"
        default: return "JPEG"
        }
    }

    var allURLs: [URL] {
        var urls = [primaryURL]
        if let paired = pairedURL { urls.append(paired) }
        return urls
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
