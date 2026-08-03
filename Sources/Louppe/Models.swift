import Foundation

enum SessionConstants {
    static let sidecarName = ".louppe_session.json"
    static let currentSchemaVersion = 4
    static let supportedSchemaVersions = 1...currentSchemaVersion
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

struct PhotoFileRatingSnapshot: Equatable, Sendable {
    let fileID: String
    let rating: Rating
    let ratedAt: Date?
}

/// The only frequently changing part of a physical file. `PhotoItem` values
/// contain substantially more immutable scan metadata, so keeping this tiny
/// pair behind shared storage lets culling update one file without copying the
/// entire `@Published [PhotoItem]` session. A lock makes snapshots safe when a
/// detached persistence/pairing worker reads a value-semantic item copy.
private final class PhotoFileRatingStorage: @unchecked Sendable {
    private struct Value {
        var rating: Rating
        var ratedAt: Date?
    }

    private let lock = NSLock()
    private var value: Value

    init(rating: Rating, ratedAt: Date?) {
        value = Value(rating: rating, ratedAt: ratedAt)
    }

    func snapshot(fileID: String) -> PhotoFileRatingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PhotoFileRatingSnapshot(
            fileID: fileID,
            rating: value.rating,
            ratedAt: value.ratedAt
        )
    }

    func set(rating: Rating, ratedAt: Date?) {
        lock.lock()
        value = Value(rating: rating, ratedAt: ratedAt)
        lock.unlock()
    }

    func setRating(_ rating: Rating) {
        lock.lock()
        value.rating = rating
        lock.unlock()
    }

    func setRatedAt(_ ratedAt: Date?) {
        lock.lock()
        value.ratedAt = ratedAt
        lock.unlock()
    }
}

/// File operations may temporarily rename an original and then put it back.
/// That changes its filesystem status timestamp without changing the photo.
/// Sharing this tiny, locked identity cell lets a background rollback refresh
/// the live session's safety checkpoint without rebuilding every PhotoItem.
private final class PhotoFileIdentityStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FileOperationJournal.FileIdentity?

    init(_ value: FileOperationJournal.FileIdentity?) {
        self.value = value
    }

    func snapshot() -> FileOperationJournal.FileIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: FileOperationJournal.FileIdentity) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

/// One physical media file and everything Louppe learned about it.
///
/// RAW+JPEG pairing is a presentation choice, so the individual files retain
/// their own metadata and ratings even while `PhotoItem` exposes them as one
/// review item. A JPEG partner discovered during a paired scan starts as a
/// lightweight record and is enriched only if separate review is requested.
struct PhotoFile: Identifiable, Sendable {
    let id: String
    /// Previous human-readable sidecars used the decoded relative path. Keep
    /// that alias for one-way migration to the byte-exact percent-encoded ID.
    let legacyPersistenceID: String
    let url: URL
    let displayName: String
    let fileTypeLabel: String
    let mediaKind: MediaKind
    let duration: TimeInterval?
    let videoDimensions: CGSize?
    let videoCodec: String?
    let videoFrameRate: Double?
    let videoIsPlayable: Bool
    let captureDate: Date?
    let captureDay: Date?
    let cameraModel: String?
    let lensModel: String?
    let subfolder: String?
    let aperture: Double?
    let shutterSpeed: Double?
    let iso: Double?
    let modificationDate: Date?
    let fileSize: Int64
    /// Physical identity captured during folder scanning. File operations and
    /// schema-4 rating restore refuse to adopt a same-path replacement.
    private let identityStorage: PhotoFileIdentityStorage
    var scannedIdentity: FileOperationJournal.FileIdentity? {
        identityStorage.snapshot()
    }
    let searchableText: String
    /// False only for a hidden JPEG partner whose filesystem facts are known
    /// but whose EXIF has deliberately not been opened yet.
    let metadataIsLoaded: Bool
    private let ratingStorage: PhotoFileRatingStorage

    var rating: Rating {
        get { ratingSnapshot.rating }
        nonmutating set { ratingStorage.setRating(newValue) }
    }

    var ratedAt: Date? {
        get { ratingSnapshot.ratedAt }
        nonmutating set { ratingStorage.setRatedAt(newValue) }
    }

    var ratingSnapshot: PhotoFileRatingSnapshot {
        ratingStorage.snapshot(fileID: id)
    }

    init(
        id: String,
        url: URL,
        displayRelativePath: String? = nil,
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
        modificationDate: Date? = nil,
        fileSize: Int64,
        scannedIdentity: FileOperationJournal.FileIdentity? = nil,
        metadataIsLoaded: Bool = true,
        rating: Rating = .undecided,
        ratedAt: Date? = nil
    ) {
        let displayName = url.lastPathComponent
        let fileTypeLabel = Self.makeFileTypeLabel(url: url, mediaKind: mediaKind)
        let legacyPersistenceID = displayRelativePath ?? id
        let subfolderPath =
            (legacyPersistenceID as NSString).deletingLastPathComponent
        let subfolder = subfolderPath.isEmpty ? nil : subfolderPath

        self.id = id
        self.legacyPersistenceID = legacyPersistenceID
        self.url = url
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
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.identityStorage = PhotoFileIdentityStorage(scannedIdentity)
        self.metadataIsLoaded = metadataIsLoaded
        self.ratingStorage = PhotoFileRatingStorage(
            rating: rating,
            ratedAt: ratedAt
        )

        var parts = [displayName, fileTypeLabel, mediaKind.label]
        if let subfolder { parts.append(subfolder) }
        if let cameraModel { parts.append(cameraModel) }
        if let lensModel { parts.append(lensModel) }
        if let captureDate { parts.append(AppDateFormat.day(captureDate)) }
        searchableText = PhotoItem.normalizeForSearch(parts.joined(separator: " "))
    }

    func setRating(_ rating: Rating, ratedAt: Date?) {
        ratingStorage.set(rating: rating, ratedAt: ratedAt)
    }

    /// Refreshes the scan-time checkpoint after a verified Louppe-owned
    /// rename/rollback. Callers capture first and publish second, so a failed
    /// stat never erases the last known identity.
    func refreshScannedIdentityFromDisk() throws {
        identityStorage.set(
            try FileOperationJournal.captureIdentity(at: url)
        )
    }

    private static func makeFileTypeLabel(url: URL, mediaKind: MediaKind) -> String {
        let ext = url.pathExtension.lowercased()
        if mediaKind == .video { return ext.isEmpty ? "VIDEO" : ext.uppercased() }
        if FolderScanner.rawExtensions.contains(ext) { return "RAW" }
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "tif", "tiff": return "TIFF"
        default: return ext.uppercased()
        }
    }
}

enum PhotoItemRatingState: Equatable, Sendable {
    case yes
    case no
    case undecided
    case mixed

    var effectiveRating: Rating {
        switch self {
        case .yes: return .yes
        case .no: return .no
        case .undecided, .mixed: return .undecided
        }
    }
}

/// Immutable identity of the physical bytes represented by a scanned item.
///
/// Relative item IDs intentionally survive a same-folder rescan, so they are
/// presentation identity rather than content identity. Async media work and
/// caches use this value instead: a same-path replacement receives a different
/// revision even when its filename and modification date were preserved.
struct PhotoContentRevision: Hashable, Sendable {
    struct Timestamp: Hashable, Sendable {
        let seconds: Int64
        let nanoseconds: Int64

        fileprivate init(_ value: FileOperationJournal.FileIdentity.Timestamp) {
            seconds = value.seconds
            nanoseconds = value.nanoseconds
        }

        fileprivate var date: Date {
            Date(
                timeIntervalSince1970:
                    TimeInterval(seconds)
                    + TimeInterval(nanoseconds) / 1_000_000_000
            )
        }

        fileprivate var cacheIdentity: String {
            "\(seconds):\(nanoseconds)"
        }
    }

    struct StableFileIdentity: Hashable, Sendable {
        let volumeRootPath: String
        let volumeUUIDString: String?
        let systemNumber: UInt64
        let fileNumber: UInt64
        let logicalSize: Int64?
        let modificationTime: Timestamp?
        let statusChangeTime: Timestamp?
        let birthTime: Timestamp?

        fileprivate init(_ value: FileOperationJournal.FileIdentity) {
            volumeRootPath = value.volumeRootPath
            volumeUUIDString = value.volumeUUIDString
            systemNumber = value.systemNumber
            fileNumber = value.fileNumber
            logicalSize = value.logicalSize
            modificationTime = value.modificationTime.map(Timestamp.init)
            statusChangeTime = value.statusChangeTime.map(Timestamp.init)
            birthTime = value.birthTime.map(Timestamp.init)
        }

        fileprivate var latestSourceTimestamp: Date? {
            [modificationTime, statusChangeTime, birthTime]
                .compactMap { $0?.date }
                .max()
        }

        fileprivate var cacheIdentity: String {
            [
                "root=\(PhotoContentRevision.encode(volumeRootPath))",
                "uuid=\(PhotoContentRevision.encode(volumeUUIDString))",
                "system=\(systemNumber)",
                "file=\(fileNumber)",
                "size=\(logicalSize.map(String.init) ?? "-")",
                "mtime=\(modificationTime?.cacheIdentity ?? "-")",
                "ctime=\(statusChangeTime?.cacheIdentity ?? "-")",
                "birth=\(birthTime?.cacheIdentity ?? "-")",
            ].joined(separator: "|")
        }
    }

    let pathIdentity: String
    let modificationTimeBits: UInt64?
    let fileSize: Int64
    let mediaKind: MediaKind
    let stableFileIdentity: StableFileIdentity?

    fileprivate init(
        pathIdentity: String,
        modificationDate: Date?,
        fileSize: Int64,
        mediaKind: MediaKind,
        scannedIdentity: FileOperationJournal.FileIdentity?
    ) {
        self.pathIdentity = pathIdentity
        self.modificationTimeBits = modificationDate?
            .timeIntervalSince1970.bitPattern
        self.fileSize = fileSize
        self.mediaKind = mediaKind
        self.stableFileIdentity = scannedIdentity.map(StableFileIdentity.init)
    }

    /// Earliest trustworthy creation time for a compatibility thumbnail. A
    /// cache file older than this scan identity could belong to a replaced file.
    var compatibilityCacheFloorDate: Date? {
        if let identityDate = stableFileIdentity?.latestSourceTimestamp {
            return identityDate
        }
        return modificationTimeBits.map {
            Date(timeIntervalSince1970: TimeInterval(bitPattern: $0))
        }
    }

    /// Stable, unambiguous text form used inside the hashed disk-cache key.
    var cacheIdentity: String {
        [
            "path=\(Self.encode(pathIdentity))",
            "mtime=\(modificationTimeBits.map(String.init) ?? "-")",
            "size=\(fileSize)",
            "kind=\(mediaKind.rawValue)",
            "identity=\(stableFileIdentity?.cacheIdentity ?? "-")",
        ].joined(separator: "|")
    }

    private static func encode(_ value: String?) -> String {
        guard let value else { return "-" }
        return "\(value.utf8.count):\(value)"
    }
}

struct PhotoItem: Identifiable, Sendable {
    /// The primary file is the visible authority while a RAW+JPEG pair is
    /// grouped. `pairedFile` still retains the JPEG's independent rating and
    /// metadata so regrouping never loses information.
    private(set) var primaryFile: PhotoFile
    private(set) var pairedFile: PhotoFile?

    var id: String { primaryFile.id }
    var primaryURL: URL { primaryFile.url }
    var pairedURL: URL? { pairedFile?.url }
    var displayName: String { primaryFile.displayName }
    var fileTypeLabel: String {
        pairedFile == nil ? primaryFile.fileTypeLabel : "RAW + JPEG"
    }
    var mediaKind: MediaKind { primaryFile.mediaKind }
    var duration: TimeInterval? { primaryFile.duration }
    var videoDimensions: CGSize? { primaryFile.videoDimensions }
    var videoCodec: String? { primaryFile.videoCodec }
    var videoFrameRate: Double? { primaryFile.videoFrameRate }
    var videoIsPlayable: Bool { primaryFile.videoIsPlayable }
    var captureDate: Date? { primaryFile.captureDate }
    var captureDay: Date? { primaryFile.captureDay }
    var cameraModel: String? { primaryFile.cameraModel }
    var lensModel: String? { primaryFile.lensModel }
    var subfolder: String? { primaryFile.subfolder }
    var aperture: Double? { primaryFile.aperture }
    var shutterSpeed: Double? { primaryFile.shutterSpeed }
    var iso: Double? { primaryFile.iso }
    var primaryModificationDate: Date? { primaryFile.modificationDate }
    var fileSize: Int64 { primaryFile.fileSize }
    var pairedFileSize: Int64 { pairedFile?.fileSize ?? 0 }
    var contentRevision: PhotoContentRevision {
        PhotoContentRevision(
            pathIdentity: primaryURL.path(percentEncoded: true),
            modificationDate: primaryModificationDate,
            fileSize: fileSize,
            mediaKind: mediaKind,
            scannedIdentity: primaryFile.scannedIdentity
        )
    }
    let searchableText: String

    var ratingState: PhotoItemRatingState {
        let primaryRating = primaryFile.rating
        guard let pairedFile else {
            switch primaryRating {
            case .yes: return .yes
            case .no: return .no
            case .undecided: return .undecided
            }
        }
        guard pairedFile.rating == primaryRating else { return .mixed }
        switch primaryRating {
        case .yes: return .yes
        case .no: return .no
        case .undecided: return .undecided
        }
    }

    /// Existing filtering/export code consumes the three-state rating. A
    /// mixed pair behaves conservatively as unresolved until the user rates
    /// it together, while `ratingState` keeps the UI honest.
    var rating: Rating {
        get { ratingState.effectiveRating }
        nonmutating set {
            primaryFile.rating = newValue
            pairedFile?.rating = newValue
        }
    }

    var ratedAt: Date? {
        get { primaryFile.ratedAt }
        nonmutating set {
            primaryFile.ratedAt = newValue
            pairedFile?.ratedAt = newValue
        }
    }

    var hasMixedRatings: Bool { ratingState == .mixed }
    var hasAnyRating: Bool {
        individualFiles.contains { $0.rating != .undecided }
    }
    var individualFiles: [PhotoFile] {
        var files = [primaryFile]
        if let pairedFile { files.append(pairedFile) }
        return files
    }
    var ratingSnapshots: [PhotoFileRatingSnapshot] {
        individualFiles.map(\.ratingSnapshot)
    }

    /// Update the pair atomically per physical file while keeping PhotoItem's
    /// much larger immutable metadata value untouched.
    func setRating(_ rating: Rating, ratedAt: Date?) {
        primaryFile.setRating(rating, ratedAt: ratedAt)
        pairedFile?.setRating(rating, ratedAt: ratedAt)
    }

    init(primaryFile: PhotoFile, pairedFile: PhotoFile? = nil) {
        self.primaryFile = primaryFile
        self.pairedFile = pairedFile
        searchableText = Self.makeSearchableText(
            primaryFile: primaryFile,
            pairedFile: pairedFile
        )
    }

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
        primaryFile = PhotoFile(
            id: id,
            url: primaryURL,
            captureDate: captureDate,
            cameraModel: cameraModel,
            lensModel: lensModel,
            aperture: aperture,
            shutterSpeed: shutterSpeed,
            iso: iso,
            mediaKind: mediaKind,
            duration: duration,
            videoDimensions: videoDimensions,
            videoCodec: videoCodec,
            videoFrameRate: videoFrameRate,
            videoIsPlayable: videoIsPlayable,
            modificationDate: primaryModificationDate,
            fileSize: fileSize,
            scannedIdentity: try? FileOperationJournal.captureIdentity(
                at: primaryURL
            ),
            rating: rating,
            ratedAt: ratedAt
        )
        if let pairedURL {
            let parent = (id as NSString).deletingLastPathComponent
            let pairedID = parent.isEmpty
                ? pairedURL.lastPathComponent
                : "\(parent)/\(pairedURL.lastPathComponent)"
            pairedFile = PhotoFile(
                id: pairedID,
                url: pairedURL,
                captureDate: captureDate,
                cameraModel: nil,
                lensModel: nil,
                modificationDate: nil,
                fileSize: pairedFileSize,
                scannedIdentity: try? FileOperationJournal.captureIdentity(
                    at: pairedURL
                ),
                metadataIsLoaded: false,
                rating: rating,
                ratedAt: ratedAt
            )
        } else {
            pairedFile = nil
        }
        searchableText = Self.makeSearchableText(
            primaryFile: primaryFile,
            pairedFile: pairedFile
        )
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

    /// Labels the camera/lens filter toggles group by. Files without EXIF
    /// (screenshots, videos…) collect under "Unknown" so they stay filterable.
    var cameraLabel: String { cameraModel ?? "Unknown" }
    var lensLabel: String { lensModel ?? "Unknown" }
    /// Root-level files collect under "None", the filter's explicit option
    /// for photos lying directly in the source folder.
    var subfolderLabel: String { subfolder ?? "None" }

    var allURLs: [URL] { individualFiles.map(\.url) }

    var totalFileSize: Int64 {
        let (total, overflowed) = fileSize.addingReportingOverflow(pairedFileSize)
        return overflowed ? Int64.max : total
    }

    func restoreRating(_ snapshot: PhotoFileRatingSnapshot) {
        if primaryFile.id == snapshot.fileID {
            primaryFile.setRating(
                snapshot.rating,
                ratedAt: snapshot.ratedAt
            )
        } else if pairedFile?.id == snapshot.fileID {
            pairedFile?.setRating(
                snapshot.rating,
                ratedAt: snapshot.ratedAt
            )
        }
    }

    private static func makeSearchableText(
        primaryFile: PhotoFile,
        pairedFile: PhotoFile?
    ) -> String {
        guard let pairedFile else { return primaryFile.searchableText }
        return normalizeForSearch(
            "\(primaryFile.searchableText) \(pairedFile.searchableText) RAW + JPEG"
        )
    }

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
    let fileCount: Int
    let photoCount: Int
    let videoCount: Int
    let cameras: [String]
    let lenses: [String]
    let captureDayRange: ClosedRange<Date>?
    let unknownDateCount: Int
    let totalBytes: Int64
    let fileTypes: [String]

    init(items: [PhotoItem]) {
        count = items.count
        fileCount = items.reduce(0) { $0 + $1.allURLs.count }
        photoCount = items.count { $0.mediaKind == .photo }
        videoCount = items.count { $0.mediaKind == .video }
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
struct PhotoSort: Equatable, Sendable {
    enum Key: Hashable, Sendable {
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
                return groupNumberBits(a.aperture) == groupNumberBits(b.aperture)
            case .shutterSpeed:
                return groupNumberBits(a.shutterSpeed) == groupNumberBits(b.shutterSpeed)
            case .iso:
                return groupNumberBits(a.iso) == groupNumberBits(b.iso)
            case .duration:
                return roundedDurationBucket(a.duration)
                    == roundedDurationBucket(b.duration)
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

        /// Stable identity for a Grid section. Unlike an enumerated array
        /// offset or the first visible photo, this survives filtering members
        /// in and out of an otherwise unchanged metadata group.
        func groupID(for item: PhotoItem) -> PhotoGroup.ID {
            let value: PhotoGroup.ID.Value
            switch self {
            case .captureDate:
                value = .date(item.captureDay)
            case .name:
                value = .ungrouped
            case .subfolder:
                value = .text(item.subfolderLabel)
            case .fileType:
                value = .text(item.fileTypeLabel)
            case .mediaKind:
                value = .mediaKind(item.mediaKind)
            case .camera:
                value = .text(item.cameraLabel)
            case .lens:
                value = .text(item.lensLabel)
            case .aperture:
                value = .numberBits(groupNumberBits(item.aperture))
            case .shutterSpeed:
                value = .numberBits(groupNumberBits(item.shutterSpeed))
            case .iso:
                value = .numberBits(groupNumberBits(item.iso))
            case .duration:
                value = .roundedDuration(roundedDurationBucket(item.duration))
            }
            return PhotoGroup.ID(key: self, value: value)
        }

        private func groupNumberBits(_ value: Double?) -> UInt64? {
            guard let value, value.isFinite else { return nil }
            // Swift considers -0 and +0 equal, so keep their group identity
            // equal too even though their raw IEEE bit patterns differ.
            return (value == 0 ? 0.0 : value).bitPattern
        }

        private func roundedDurationBucket(_ value: TimeInterval?) -> Int? {
            MediaNumeric.roundedNonnegativeInt(value)
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
struct PhotoGroup: Equatable, Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        enum Value: Hashable, Sendable {
            case ungrouped
            case date(Date?)
            case text(String)
            case mediaKind(MediaKind)
            case numberBits(UInt64?)
            case roundedDuration(Int?)
        }

        let key: PhotoSort.Key?
        let value: Value

        static let ungrouped = ID(key: nil, value: .ungrouped)
    }

    let id: ID
    let title: String?
    let indices: [Int]
}

/// Total validation and rounded conversions for untrusted media metadata.
enum MediaNumeric {
    private static func finiteValue(
        _ value: Double?,
        in range: ClosedRange<Double>
    ) -> Double? {
        guard let value, value.isFinite, range.contains(value) else {
            return nil
        }
        return value
    }

    /// A rounded conversion that cannot trap at the floating-point edges.
    ///
    /// `Double(Int.max)` rounds up to 2^63 on 64-bit platforms, so comparing
    /// against that value before calling `Int(...)` is not sufficient.
    static func roundedNonnegativeInt(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return Int(exactly: value.rounded())
    }

    static func roundedPositiveInt(_ value: Double?) -> Int? {
        guard let rounded = roundedNonnegativeInt(value),
              rounded > 0 else { return nil }
        return rounded
    }

    // Deliberately generous physical/display limits. They reject corrupt
    // finite metadata without excluding plausible specialist equipment.
    static func aperture(_ value: Double?) -> Double? {
        finiteValue(value, in: 0.1...1_024)
    }

    static func iso(_ value: Double?) -> Double? {
        finiteValue(value, in: 1...10_000_000)
    }

    static func focalLength(_ value: Double?) -> Double? {
        finiteValue(value, in: 1...100_000)
    }

    static func frameRate(_ value: Double?) -> Double? {
        finiteValue(value, in: 0.01...1_000_000)
    }

    static func exposureCompensation(_ value: Double?) -> Double? {
        finiteValue(value, in: -100...100)
    }

    static func latitude(_ value: Double?) -> Double? {
        finiteValue(value, in: -90...90)
    }

    static func longitude(_ value: Double?) -> Double? {
        finiteValue(value, in: -180...180)
    }

    static func duration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value,
              roundedNonnegativeInt(value) != nil else { return nil }
        return value
    }

    static func shutterSpeed(_ value: Double?) -> Double? {
        guard let value = finiteValue(
            value,
            in: (1.0 / 1_000_000_000)...86_400
        ) else { return nil }
        if value < 1 {
            guard roundedPositiveInt(1 / value) != nil else { return nil }
        }
        return value
    }

    static func pixelDimension(_ value: CGFloat) -> Int? {
        guard let value = finiteValue(
            Double(value),
            in: 1...1_000_000
        ) else { return nil }
        return roundedPositiveInt(value)
    }
}

/// EXIF value formatting shared by the filter fields and group headers.
enum MetadataFormat {
    static func decimal(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "" }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func shutter(_ seconds: Double) -> String {
        guard let seconds = MediaNumeric.shutterSpeed(seconds) else {
            return ""
        }
        if seconds >= 1 {
            return "\(decimal(seconds))s"
        }
        guard let denominator = MediaNumeric.roundedPositiveInt(1 / seconds)
        else { return "" }
        if abs(seconds - (1 / Double(denominator))) < 0.000_001 {
            return "1/\(denominator)"
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
    /// Required by schema 4. Older sidecars remain readable for one-way
    /// migration, but current ratings are restored only onto this exact
    /// scanned physical file rather than whichever file now owns the path.
    var fileIdentity: FileOperationJournal.FileIdentity? = nil
}

struct SessionFile: Codable, Sendable {
    enum FileIDEncoding: String, Codable, Sendable {
        case percentEncodedFileSystemPath
    }

    var version: Int
    var sourcePath: String
    var scannedAt: Date
    var entries: [SessionEntry]
    /// Required by schema 3 and newer. Absent in legacy schema-1/2 snapshots
    /// whose IDs were decoded paths. Keeping the marker optional preserves
    /// legacy reads while making a downgrade fail safely.
    var fileIDEncoding: FileIDEncoding? = nil
    /// Actor-assigned durable ordering for current snapshots. Older sidecars
    /// omit it and remain readable; once present, this counter is authoritative
    /// over wall-clock timestamps when choosing between sidecar and backup.
    var snapshotGeneration: UInt64? = nil
}

/// Resolves sidecar ratings by byte-exact file ID, with a read-only fallback
/// for sidecars written before IDs became percent-encoded. New saves always
/// write the exact ID, so canonically equivalent filenames remain independent.
struct SessionRatingIndex {
    struct Value: Equatable {
        let rating: Rating
        let ratedAt: Date?
        let fileIdentity: FileOperationJournal.FileIdentity?
    }

    struct Match: Equatable {
        let value: Value
        /// Exact ID used by the loaded sidecar. It may differ from the live
        /// file ID when the same verified physical file was renamed.
        let persistedFileID: String
        /// Byte spelling used for migration coverage. Swift String equality
        /// folds NFC/NFD equivalents that can be distinct filesystem names.
        let persistedFileIDBytes: Data
    }

    /// A missing sidecar entry and a same-path replacement have very
    /// different safety consequences. The former is a new file; the latter
    /// means an existing saved rating belongs to a different physical file
    /// and the current sidecar must not be rewritten automatically.
    enum Lookup: Equatable {
        case absent
        case match(Match)
        case identityConflict(Match)
    }

    private struct PersistedIdentityKey: Hashable {
        enum Volume: Hashable {
            case uuid(String)
            case legacy(root: String, systemNumber: UInt64)
        }

        let volume: Volume
        let fileNumber: UInt64
        let logicalSize: Int64?
        let modificationSeconds: Int64?
        let modificationNanoseconds: Int64?
        let birthSeconds: Int64?
        let birthNanoseconds: Int64?

        init(_ identity: FileOperationJournal.FileIdentity) {
            if let uuid = identity.volumeUUIDString {
                volume = .uuid(uuid)
            } else {
                volume = .legacy(
                    root: identity.volumeRootPath,
                    systemNumber: identity.systemNumber
                )
            }
            fileNumber = identity.fileNumber
            logicalSize = identity.logicalSize
            modificationSeconds = identity.modificationTime?.seconds
            modificationNanoseconds = identity.modificationTime?.nanoseconds
            birthSeconds = identity.birthTime?.seconds
            birthNanoseconds = identity.birthTime?.nanoseconds
        }
    }

    private enum IdentityCandidate {
        case unique(Match)
        case ambiguous
    }

    private let exactValuesByFileID: [String: Value]
    private let legacyValuesByUTF8ID: [Data: Value]
    private let valuesByPhysicalIdentity: [PersistedIdentityKey: IdentityCandidate]
    let persistedPhysicalFileIDBytes: Set<Data>
    private let allowsLegacyAliases: Bool
    private let requiresPhysicalIdentity: Bool

    init(session: SessionFile) {
        let usesExactIDs =
            session.fileIDEncoding == .percentEncodedFileSystemPath
        var exactValues: [String: Value] = [:]
        var legacyValues: [Data: Value] = [:]
        var identityValues: [PersistedIdentityKey: IdentityCandidate] = [:]
        var physicalFileIDBytes = Set<Data>()
        for entry in session.entries {
            let value = Value(
                rating: Rating(rawValue: entry.rating) ?? .undecided,
                ratedAt: entry.ratedAt,
                fileIdentity: entry.fileIdentity
            )
            if usesExactIDs {
                // Exact IDs contain ASCII percent escapes, so Swift's
                // canonical-equivalent String equality cannot merge them.
                exactValues[entry.filename] = value
                if session.version >= 4,
                   let identity = entry.fileIdentity {
                    let key = PersistedIdentityKey(identity)
                    let match = Match(
                        value: value,
                        persistedFileID: entry.filename,
                        persistedFileIDBytes: Data(entry.filename.utf8)
                    )
                    if identityValues[key] == nil {
                        identityValues[key] = .unique(match)
                    } else {
                        // Hard-linked or corrupt duplicate identities are
                        // still safe by exact path, but never drive a rename.
                        identityValues[key] = .ambiguous
                    }
                }
            } else {
                // Legacy IDs are decoded paths. Preserve their underlying
                // UTF-8 spellings: NFC and NFD filenames can coexist on a
                // normalization-sensitive filesystem and need independent
                // ratings.
                legacyValues[Data(entry.filename.utf8)] = value
            }
            physicalFileIDBytes.insert(Data(entry.filename.utf8))
            if let pairedFilename = entry.pairedFilename {
                let pairedID: String
                if let separator = entry.filename.lastIndex(of: "/") {
                    pairedID =
                        "\(entry.filename[..<separator])/\(pairedFilename)"
                } else {
                    pairedID = pairedFilename
                }
                if usesExactIDs {
                    exactValues[pairedID] = value
                } else {
                    legacyValues[Data(pairedID.utf8)] = value
                }
                physicalFileIDBytes.insert(Data(pairedID.utf8))
            }
        }
        exactValuesByFileID = exactValues
        legacyValuesByUTF8ID = legacyValues
        valuesByPhysicalIdentity = identityValues
        persistedPhysicalFileIDBytes = physicalFileIDBytes
        allowsLegacyAliases = !usesExactIDs
        requiresPhysicalIdentity = session.version >= 4
    }

    func lookup(for file: PhotoFile) -> Lookup {
        if let exact = exactValuesByFileID[file.id] {
            guard !requiresPhysicalIdentity else {
                guard let expected = exact.fileIdentity,
                      let actual = file.scannedIdentity else {
                    return .identityConflict(Match(
                        value: exact,
                        persistedFileID: file.id,
                        persistedFileIDBytes: Data(file.id.utf8)
                    ))
                }
                if Self.persistedIdentityMatches(
                        expected: expected,
                        actual: actual
                ) {
                    return .match(Match(
                        value: exact,
                        persistedFileID: file.id,
                        persistedFileIDBytes: Data(file.id.utf8)
                    ))
                }
                if let renamed = identityMatch(for: actual),
                   renamed.persistedFileID != file.id {
                    return .match(renamed)
                }
                return .identityConflict(Match(
                    value: exact,
                    persistedFileID: file.id,
                    persistedFileIDBytes: Data(file.id.utf8)
                ))
            }
            return .match(Match(
                value: exact,
                persistedFileID: file.id,
                persistedFileIDBytes: Data(file.id.utf8)
            ))
        }
        if requiresPhysicalIdentity,
           let actual = file.scannedIdentity,
           let renamed = identityMatch(for: actual) {
            return .match(renamed)
        }
        guard allowsLegacyAliases,
              let legacy = legacyValuesByUTF8ID[
                Data(file.legacyPersistenceID.utf8)
              ] else { return .absent }
        return .match(Match(
            value: legacy,
            persistedFileID: file.legacyPersistenceID,
            persistedFileIDBytes: Data(file.legacyPersistenceID.utf8)
        ))
    }

    func value(for file: PhotoFile) -> Value? {
        guard case .match(let match) = lookup(for: file) else { return nil }
        return match.value
    }

    private func identityMatch(
        for identity: FileOperationJournal.FileIdentity
    ) -> Match? {
        guard case .unique(let match) = valuesByPhysicalIdentity[
            PersistedIdentityKey(identity)
        ] else {
            return nil
        }
        return match
    }

    /// Persistence follows content identity across remounts. A stable volume
    /// UUID supersedes the transient mount path and device number; filesystems
    /// without one retain the conservative legacy volume checks. ctime is
    /// deliberately ignored because moving a file can change it without
    /// changing the photographed content.
    static func persistedIdentityMatches(
        expected: FileOperationJournal.FileIdentity,
        actual: FileOperationJournal.FileIdentity
    ) -> Bool {
        let sameVolume: Bool
        if let expectedUUID = expected.volumeUUIDString {
            sameVolume = actual.volumeUUIDString == expectedUUID
        } else {
            sameVolume = actual.volumeRootPath == expected.volumeRootPath
                && actual.systemNumber == expected.systemNumber
        }
        return sameVolume
            && actual.fileNumber == expected.fileNumber
            && actual.logicalSize == expected.logicalSize
            && actual.modificationTime == expected.modificationTime
            && actual.birthTime == expected.birthTime
    }
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
