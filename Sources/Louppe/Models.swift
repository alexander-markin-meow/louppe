import Foundation

enum SessionConstants {
    static let sidecarName = ".louppe_session.json"
}

enum Rating: String, Codable, Sendable {
    case undecided
    case yes
    case no
}

enum MediaKind: String, Hashable, Sendable {
    case photo
    case video

    var label: String {
        switch self {
        case .photo: return "Photos"
        case .video: return "Videos"
        }
    }
}

enum RawJPEGPairingMode: String, Hashable, Sendable {
    case together
    case separate
}

struct PhotoItem: Identifiable, Sendable {
    /// Relative path of the primary file within the source folder — stable session key.
    let id: String
    let primaryURL: URL
    let pairedURL: URL?
    /// Stable display/filter facets cached once rather than rebuilt during
    /// every filter pass and sort comparison.
    let displayName: String
    let fileTypeLabel: String
    let mediaKind: MediaKind
    /// Movie properties are read once during scanning. Images keep these nil;
    /// views and filters never reopen every movie while scrolling or typing.
    let duration: TimeInterval?
    let videoDimensions: CGSize?
    let videoCodec: String?
    let videoFrameRate: Double?
    let videoIsPlayable: Bool
    let captureDate: Date?
    /// Calendar-day bucket used by the specific-date filter. Capture dates are
    /// immutable, so normalizing once avoids rebuilding date components for
    /// every photo whenever a checkbox changes.
    let captureDay: Date?
    /// Camera + lens read once during the scan, so the filter search can
    /// match them without re-opening every file.
    let cameraModel: String?
    let lensModel: String?
    /// Directory part of `id` — the subfolder path relative to the source
    /// folder. Nil for files lying directly in the source folder.
    let subfolder: String?
    /// Exposure metadata is cached during the folder scan. Shutter speed is
    /// stored as exposure duration in seconds; aperture and ISO are numeric.
    let aperture: Double?
    let shutterSpeed: Double?
    let iso: Double?
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
        aperture: Double? = nil,
        shutterSpeed: Double? = nil,
        iso: Double? = nil,
        mediaKind: MediaKind = .photo,
        duration: TimeInterval? = nil,
        videoDimensions: CGSize? = nil,
        videoCodec: String? = nil,
        videoFrameRate: Double? = nil,
        videoIsPlayable: Bool = false,
        primaryModificationDate: Date? = nil,
        fileSize: Int64,
        pairedFileSize: Int64 = 0,
        rating: Rating = .undecided,
        ratedAt: Date? = nil
    ) {
        let displayName = primaryURL.lastPathComponent
        let fileTypeLabel = Self.makeFileTypeLabel(
            primaryURL: primaryURL,
            pairedURL: pairedURL,
            mediaKind: mediaKind
        )
        let subfolderPath = (id as NSString).deletingLastPathComponent
        let subfolder = subfolderPath.isEmpty ? nil : subfolderPath
        self.id = id
        self.primaryURL = primaryURL
        self.pairedURL = pairedURL
        self.displayName = displayName
        self.fileTypeLabel = fileTypeLabel
        self.mediaKind = mediaKind
        self.duration = duration
        self.videoDimensions = videoDimensions
        self.videoCodec = videoCodec
        self.videoFrameRate = videoFrameRate
        self.videoIsPlayable = videoIsPlayable
        self.captureDate = captureDate
        self.captureDay = captureDate.map { Calendar.current.startOfDay(for: $0) }
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.subfolder = subfolder
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.primaryModificationDate = primaryModificationDate
        self.fileSize = fileSize
        self.pairedFileSize = pairedFileSize
        self.rating = rating
        self.ratedAt = ratedAt

        var parts = [displayName, fileTypeLabel, mediaKind.label]
        if let paired = pairedURL?.lastPathComponent { parts.append(paired) }
        if let subfolder { parts.append(subfolder) }
        if let cameraModel { parts.append(cameraModel) }
        if let lensModel { parts.append(lensModel) }
        if let captureDate { parts.append(AppDateFormat.day(captureDate)) }
        searchableText = Self.normalizeForSearch(parts.joined(separator: " "))
    }

    var isRaw: Bool {
        FolderScanner.rawExtensions.contains(primaryURL.pathExtension.lowercased())
    }

    var isVideo: Bool { mediaKind == .video }

    /// Whether we can actually decode and preview this file. Unsupported visual
    /// files still appear in the session, just as a placeholder tile.
    var isSupported: Bool {
        if isVideo { return videoIsPlayable }
        return FolderScanner.supportedExtensions.contains(primaryURL.pathExtension.lowercased())
    }

    private static func makeFileTypeLabel(
        primaryURL: URL,
        pairedURL: URL?,
        mediaKind: MediaKind
    ) -> String {
        if pairedURL != nil { return "RAW + JPEG" }
        let ext = primaryURL.pathExtension.lowercased()
        if mediaKind == .video { return ext.isEmpty ? "VIDEO" : ext.uppercased() }
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
    /// Root-level files collect under "None", the filter's explicit option
    /// for photos lying directly in the source folder.
    var subfolderLabel: String { subfolder ?? "None" }

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
}

// MARK: - Multi-selection metadata

/// The small, scan-metadata-only summary shown by the Info panel when several
/// photo items are selected. Building it never reopens files, and distinct
/// camera/lens/type values are retained rather than collapsed to “Mixed”.
struct PhotoSelectionSummary: Equatable {
    let count: Int
    let cameras: [String]
    let lenses: [String]
    let captureDayRange: ClosedRange<Date>?
    let unknownDateCount: Int
    let totalBytes: Int64
    let fileTypes: [String]

    init(items: [PhotoItem]) {
        count = items.count
        cameras = Self.distinctMetadataLabels(items.map(\.cameraModel))
        lenses = Self.distinctMetadataLabels(items.map(\.lensModel))

        let captureDays = items.compactMap(\.captureDay)
        captureDayRange = captureDays.min().flatMap { earliest in
            captureDays.max().map { earliest...$0 }
        }
        unknownDateCount = items.count - captureDays.count

        totalBytes = items.reduce(into: Int64(0)) { total, item in
            let (sum, overflowed) = total.addingReportingOverflow(item.totalFileSize)
            total = overflowed ? Int64.max : sum
        }
        fileTypes = Set(items.map(\.fileTypeLabel)).sorted(by: Self.localizedOrder)
    }

    private static func distinctMetadataLabels(_ values: [String?]) -> [String] {
        var known = Set<String>()
        var hasUnknown = false
        for value in values {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                known.insert(value)
            } else {
                hasUnknown = true
            }
        }
        var result = known.sorted(by: localizedOrder)
        if hasUnknown { result.append("Unknown") }
        return result
    }

    private static func localizedOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

// MARK: - Clean up

/// Which photos the two rating-based Clean Up actions are allowed to
/// consider. Trashing the selection directly is intentionally independent of
/// this choice.
enum CleanUpScope: Hashable, Sendable {
    case all
    case filtered
    case selected

    func candidateIndices(
        all: Range<Int>,
        filtered: [Int],
        selected: Set<Int>
    ) -> [Int] {
        switch self {
        case .all:
            return Array(all)
        case .filtered:
            return filtered
        case .selected:
            return selected.sorted()
        }
    }
}

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

// MARK: - Export

/// What the Export dialog does with the files of the chosen ratings.
enum ExportMode: Equatable, Sendable {
    /// Duplicate the files at the destination; originals stay untouched.
    case copy
    /// Transfer the files to the destination. Moved photos leave the session,
    /// and the move is not undoable in Louppe — the files themselves stay
    /// intact at the destination.
    case move
}

// MARK: - Session sort

/// How the toolbar sort menu orders the visible photos.
struct PhotoSort: Equatable {
    enum Key: Hashable {
        case captureDate
        case name
        case subfolder
        case fileType
        case mediaKind
        case camera
        case lens
        case aperture
        case shutterSpeed
        case iso
        case duration

        var ascendingLabel: String {
            switch self {
            case .captureDate: return "Oldest first"
            case .name, .subfolder, .fileType, .camera, .lens: return "A–Z"
            case .mediaKind: return "Photos first"
            case .aperture: return "Widest first"
            case .shutterSpeed: return "Fastest first"
            case .iso: return "Lowest first"
            case .duration: return "Shortest first"
            }
        }

        var descendingLabel: String {
            switch self {
            case .captureDate: return "Newest first"
            case .name, .subfolder, .fileType, .camera, .lens: return "Z–A"
            case .mediaKind: return "Videos first"
            case .aperture: return "Narrowest first"
            case .shutterSpeed: return "Slowest first"
            case .iso: return "Highest first"
            case .duration: return "Longest first"
            }
        }

        /// Whether two adjacent photos in the sorted order belong to the same
        /// group. Name sorting never divides — every file name is unique, so
        /// groups would be meaningless.
        func sameGroup(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
            switch self {
            case .captureDate:
                // Compare the day buckets cached at scan time; fetching
                // Calendar.current per adjacent pair made every group rebuild
                // pay a calendar lookup for each visible photo.
                return a.captureDay == b.captureDay
            case .name:
                return true
            case .subfolder:
                return a.subfolderLabel == b.subfolderLabel
            case .fileType:
                return a.fileTypeLabel == b.fileTypeLabel
            case .mediaKind:
                return a.mediaKind == b.mediaKind
            case .camera:
                return a.cameraLabel == b.cameraLabel
            case .lens:
                return a.lensLabel == b.lensLabel
            case .aperture:
                return a.aperture == b.aperture
            case .shutterSpeed:
                return a.shutterSpeed == b.shutterSpeed
            case .iso:
                return a.iso == b.iso
            case .duration:
                return a.duration.map { Int($0.rounded()) } == b.duration.map { Int($0.rounded()) }
            }
        }

        /// The header label for the group a photo opens, shown above dividers
        /// in the Grid and the Browser strip.
        func groupTitle(for item: PhotoItem) -> String {
            switch self {
            case .captureDate:
                guard let date = item.captureDate else { return "Unknown date" }
                return AppDateFormat.day(date)
            case .name:
                return ""
            case .subfolder:
                return item.subfolderLabel
            case .fileType:
                return item.fileTypeLabel
            case .mediaKind:
                return item.mediaKind.label
            case .camera:
                return item.cameraLabel
            case .lens:
                return item.lensLabel
            case .aperture:
                guard let aperture = item.aperture else { return "Unknown aperture" }
                return "f/\(MetadataFormat.decimal(aperture))"
            case .shutterSpeed:
                guard let shutter = item.shutterSpeed else { return "Unknown shutter speed" }
                return MetadataFormat.shutter(shutter)
            case .iso:
                guard let iso = item.iso else { return "Unknown ISO" }
                return "ISO \(MetadataFormat.iso(iso))"
            case .duration:
                return item.duration.map { MediaDurationFormat.display($0) } ?? "Unknown duration"
            }
        }
    }
    var key: Key = .captureDate
    var ascending = true

    /// Comparator for the session's visible order. Photos without a capture
    /// date always sort to the end, whichever direction is chosen.
    func areInOrder(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        switch key {
        case .captureDate:
            return optionalValuesInOrder(a.captureDate, b.captureDate, ascending: ascending) {
                namesInOrder(a, b, ascending: true)
            }
        case .name:
            return namesInOrder(a, b, ascending: ascending)
        case .subfolder:
            return optionalStringsInOrder(a.subfolder, b.subfolder, ascending: ascending) {
                dateThenNameInOrder(a, b)
            }
        case .fileType:
            return stringsInOrder(a.fileTypeLabel, b.fileTypeLabel, ascending: ascending) {
                dateThenNameInOrder(a, b)
            }
        case .mediaKind:
            let aValue = a.mediaKind == .photo ? 0 : 1
            let bValue = b.mediaKind == .photo ? 0 : 1
            if aValue != bValue { return ascending ? aValue < bValue : aValue > bValue }
            return dateThenNameInOrder(a, b)
        case .camera:
            return optionalStringsInOrder(a.cameraModel, b.cameraModel, ascending: ascending) {
                dateThenNameInOrder(a, b)
            }
        case .lens:
            return optionalStringsInOrder(a.lensModel, b.lensModel, ascending: ascending) {
                dateThenNameInOrder(a, b)
            }
        case .aperture:
            return optionalValuesInOrder(a.aperture, b.aperture, ascending: ascending) {
                dateThenNameInOrder(a, b)
            }
        case .shutterSpeed:
            return optionalValuesInOrder(a.shutterSpeed, b.shutterSpeed, ascending: ascending) {
                dateThenNameInOrder(a, b)
            }
        case .iso:
            return optionalValuesInOrder(a.iso, b.iso, ascending: ascending) {
                dateThenNameInOrder(a, b)
            }
        case .duration:
            return optionalValuesInOrder(a.duration, b.duration, ascending: ascending) {
                dateThenNameInOrder(a, b)
            }
        }
    }

    /// Finder-style name comparison (numbers compare numerically, so
    /// IMG_9 comes before IMG_10). Ties break on the stable id.
    private func namesInOrder(_ a: PhotoItem, _ b: PhotoItem, ascending: Bool) -> Bool {
        let comparison = a.displayName.localizedStandardCompare(b.displayName)
        if comparison != .orderedSame {
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return a.id < b.id
    }

    /// Equal metadata values stay chronological, then Finder-name ordered.
    /// This tie-break is deliberately independent of the primary direction,
    /// making repeated sorts stable and predictable.
    private func dateThenNameInOrder(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        optionalValuesInOrder(a.captureDate, b.captureDate, ascending: true) {
            namesInOrder(a, b, ascending: true)
        }
    }

    private func optionalValuesInOrder<Value: Comparable>(
        _ a: Value?,
        _ b: Value?,
        ascending: Bool,
        tie: () -> Bool
    ) -> Bool {
        switch (a, b) {
        case let (a?, b?) where a != b:
            return ascending ? a < b : a > b
        case (.some, .some), (nil, nil):
            return tie()
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        }
    }

    private func stringsInOrder(
        _ a: String,
        _ b: String,
        ascending: Bool,
        tie: () -> Bool
    ) -> Bool {
        let comparison = a.localizedStandardCompare(b)
        guard comparison != .orderedSame else { return tie() }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func optionalStringsInOrder(
        _ a: String?,
        _ b: String?,
        ascending: Bool,
        tie: () -> Bool
    ) -> Bool {
        switch (a, b) {
        case let (a?, b?):
            return stringsInOrder(a, b, ascending: ascending, tie: tie)
        case (nil, nil):
            return tie()
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        }
    }

}

/// One run of visible photos that share the active sort key's value.
/// `title` is nil when division is off (or the key never divides), which
/// tells the views to draw no header at all.
struct PhotoGroup: Equatable {
    let title: String?
    let indices: [Int]
}

/// EXIF value formatting shared by the filter fields and group headers.
enum MetadataFormat {
    static func decimal(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "" }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func shutter(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds >= 1 {
            return "\(decimal(seconds))s"
        }
        let denominator = (1 / seconds).rounded()
        if denominator >= 1, abs(seconds - (1 / denominator)) < 0.000_001 {
            return "1/\(Int(denominator))"
        }
        return "\(decimal(seconds))s"
    }

    static func iso(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "" }
        return String(format: "%.0f", value)
    }
}

// MARK: - Session filter

enum DateFilterMode: Hashable {
    case range
    case specificDates
}

/// What the toolbar filter menu narrows the session down to.
/// An inactive filter shows everything.
struct PhotoFilter: Equatable {
    var searchText = ""
    /// These `Enabled` flags are internal effect flags, not UI toggles. The
    /// controls are always present; a flag becomes true only when the user
    /// narrows that folder-wide range (or unchecks a specific date).
    var dateEnabled = false
    var dateMode: DateFilterMode = .range
    var dateFrom = Date()
    var dateTo = Date()
    /// Exclusion sets make every discovered date visible by default and keep
    /// newly discovered values included after a future structural refresh.
    var excludedDates: Set<Date> = []
    var excludesUnknownDate = false
    var apertureEnabled = false
    var apertureFrom = 0.0
    var apertureTo = 0.0
    var shutterEnabled = false
    var shutterFrom = 0.0
    var shutterTo = 0.0
    var isoEnabled = false
    var isoFrom = 0.0
    var isoTo = 0.0
    var durationEnabled = false
    var durationFrom = 0.0
    var durationTo = 0.0
    /// Media categories switched off in a mixed photo/video folder.
    var excludedMediaKinds: Set<MediaKind> = []
    /// File-type labels the user has switched off. Empty = all types shown,
    /// so newly appearing types after a re-scan default to visible.
    var excludedTypes: Set<String> = []
    /// Same exclusion pattern for camera and lens labels.
    var excludedCameras: Set<String> = []
    var excludedLenses: Set<String> = []
    /// Same exclusion pattern for subfolder labels ("None" = the folder root).
    var excludedSubfolders: Set<String> = []

    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || dateEnabled
            || apertureEnabled
            || shutterEnabled
            || isoEnabled
            || durationEnabled
            || !excludedMediaKinds.isEmpty
            || !excludedTypes.isEmpty
            || !excludedCameras.isEmpty
            || !excludedLenses.isEmpty
            || !excludedSubfolders.isEmpty
    }

}

/// Expensive, filter-wide work (date bounds and query normalization) is done
/// once before walking the photo list.
struct PreparedPhotoFilter {
    let excludedMediaKinds: Set<MediaKind>
    let excludedTypes: Set<String>
    let excludedCameras: Set<String>
    let excludedLenses: Set<String>
    let excludedSubfolders: Set<String>
    let dateRange: Range<Date>?
    let usesSpecificDates: Bool
    let excludedDates: Set<Date>
    let excludesUnknownDate: Bool
    let apertureRange: ClosedRange<Double>?
    let shutterRange: ClosedRange<Double>?
    let isoRange: ClosedRange<Double>?
    let durationRange: ClosedRange<Double>?
    let searchTokens: [Substring]

    init(_ filter: PhotoFilter, calendar: Calendar = .current) {
        excludedMediaKinds = filter.excludedMediaKinds
        excludedTypes = filter.excludedTypes
        excludedCameras = filter.excludedCameras
        excludedLenses = filter.excludedLenses
        excludedSubfolders = filter.excludedSubfolders
        usesSpecificDates = filter.dateEnabled && filter.dateMode == .specificDates
        excludedDates = filter.excludedDates
        excludesUnknownDate = filter.excludesUnknownDate
        if filter.dateEnabled, filter.dateMode == .range,
           let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: filter.dateTo)) {
            dateRange = calendar.startOfDay(for: filter.dateFrom)..<end
        } else {
            dateRange = nil
        }
        apertureRange = Self.validRange(
            enabled: filter.apertureEnabled,
            from: filter.apertureFrom,
            to: filter.apertureTo
        )
        shutterRange = Self.validRange(
            enabled: filter.shutterEnabled,
            from: filter.shutterFrom,
            to: filter.shutterTo
        )
        isoRange = Self.validRange(
            enabled: filter.isoEnabled,
            from: filter.isoFrom,
            to: filter.isoTo
        )
        durationRange = Self.validRange(
            enabled: filter.durationEnabled,
            from: filter.durationFrom,
            to: filter.durationTo,
            allowsZero: true
        )
        let query = PhotoItem.normalizeForSearch(filter.searchText.trimmingCharacters(in: .whitespaces))
        searchTokens = query.split(whereSeparator: \.isWhitespace)
    }

    func matches(_ item: PhotoItem) -> Bool {
        if excludedMediaKinds.contains(item.mediaKind) { return false }
        if excludedTypes.contains(item.fileTypeLabel) { return false }
        if excludedCameras.contains(item.cameraLabel) { return false }
        if excludedLenses.contains(item.lensLabel) { return false }
        if excludedSubfolders.contains(item.subfolderLabel) { return false }
        if let dateRange {
            guard let date = item.captureDate, dateRange.contains(date) else { return false }
        }
        if usesSpecificDates {
            if let day = item.captureDay {
                if excludedDates.contains(day) { return false }
            } else if excludesUnknownDate {
                return false
            }
        }
        if let apertureRange {
            guard let aperture = item.aperture, apertureRange.contains(aperture) else { return false }
        }
        if let shutterRange {
            guard let shutterSpeed = item.shutterSpeed, shutterRange.contains(shutterSpeed) else { return false }
        }
        if let isoRange {
            guard let iso = item.iso, isoRange.contains(iso) else { return false }
        }
        if let durationRange {
            guard let duration = item.duration, durationRange.contains(duration) else { return false }
        }
        for token in searchTokens where !item.searchableText.contains(token) {
            return false
        }
        return true
    }

    private static func validRange(
        enabled: Bool,
        from: Double,
        to: Double,
        allowsZero: Bool = false
    ) -> ClosedRange<Double>? {
        guard enabled, from.isFinite, to.isFinite,
              (allowsZero ? from >= 0 : from > 0),
              from <= to else { return nil }
        return from...to
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
