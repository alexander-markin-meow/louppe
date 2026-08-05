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

enum SessionEmptyReason: Equatable, Sendable {
    case trashedUndoable
    case movedOut
    case unavailableAfterFailedRestore
}

enum XMPPublicationLifecycleState: Equatable, Sendable {
    case idle
    case preflighting(done: Int, total: Int)
    case awaitingConfirmation(XMPPublicationPlan)
    case publishing(done: Int, total: Int)
    case cancelling
    case finished(XMPPublicationResult)
    case failed(String)
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
    @Published private(set) var emptySessionReason: SessionEmptyReason?
    /// A non-blocking warning when ratings are safe only in Louppe's backup,
    /// or are not currently persisted anywhere. A successful sidecar write
    /// clears it automatically.
    @Published private(set) var persistenceWarning: String?
    private var persistenceRejectedInvalidSnapshot = false
    /// Filename-only schema 1–3 ratings migrate automatically when every
    /// saved filename is still present in its original folder. Missing or
    /// unowned legacy entries require an explicit choice before anything is
    /// saved.
    @Published private(set) var isLegacySessionMigrationConfirmationPresented = false
    @Published private(set) var legacySessionMigrationMissingFileCount = 0
    @Published private(set) var legacySessionMigrationUsesUnownedBackup = false
    /// Schema-4 ratings whose physical files were absent during the latest
    /// scan. They remain in subsequent snapshots until the exact file returns
    /// or Louppe itself explicitly removes that file from a live session.
    /// This prevents a temporarily disconnected/moved original from losing
    /// its decision merely because another photo triggered an automatic save.
    private var retainedMissingSessionEntries: [SessionEntry] = []
    var canRetryPersistence: Bool {
        let hasLiveSession: Bool
        if sourceFolder != nil,
           persistenceAccess != nil,
           case .ready = phase,
           !isLegacySessionMigrationConfirmationPresented {
            hasLiveSession = true
        } else {
            hasLiveSession = false
        }
        return persistenceWarning != nil
            && !persistenceRejectedInvalidSnapshot
            && activePersistenceSaveCount == 0
            && (hasLiveSession || retrySaveRequest != nil)
    }
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
    @Published private(set) var activeFileOperation: FileOperationKind? {
        didSet { updateFileOperationPowerActivity() }
    }
    @Published private(set) var xmpPublicationState:
        XMPPublicationLifecycleState = .idle {
        didSet { updateFileOperationPowerActivity() }
    }
    @Published private(set) var isSessionTransitioning = false
    @Published private(set) var isPreparingForTermination = false
    @Published private(set) var isRecoveringInterruptedOperations = false {
        didSet { updateFileOperationPowerActivity() }
    }
    @Published private(set) var operationRecoveryReport:
        FileOperationJournal.RecoveryReport?
    /// The worker's concrete reason for entering recovery. Launch recovery
    /// cannot always know why a previous process stopped, but an in-process
    /// I/O failure must not be reduced to a generic "interrupted" notice.
    @Published private(set) var operationRecoveryCause: String?
    @Published private(set) var recoveryNeedsAttention = false
    /// True only while Louppe is actively changing state or checking an
    /// interrupted operation. A persistent recovery warning is deliberately
    /// not part of this gate: review and session management stay usable.
    var isFileOperationRunning: Bool {
        activeFileOperation != nil
            || isSessionTransitioning
            || isPreparingForTermination
            || isRecoveringInterruptedOperations
    }
    /// An unresolved journal reserves filesystem mutations for Recovery. It
    /// does not reserve ordinary review, ratings, navigation, or persistence.
    var isNewFileOperationBlocked: Bool {
        isFileOperationRunning || isXMPPublicationRunning
            || recoveryNeedsAttention
    }
    /// Successful recovery only needs acknowledgement when it did something
    /// visible. Merely verifying and retiring a stale record is silent.
    var operationRecoveryReportRequiresAcknowledgement: Bool {
        guard let report = operationRecoveryReport,
              !Self.recoveryReportNeedsAttention(report) else { return false }
        return report.preservedCopies > 0
            || report.preservedMoves > 0
            || report.restoredFiles > 0
            || report.removedPartialCopies > 0
    }
    /// One concise explanation for the nonmodal warning. Reconnecting a
    /// drive is suggested only when Recovery actually found an unavailable
    /// volume; identity mismatches and lock contention need different advice.
    var recoveryAttentionMessage: String? {
        guard recoveryNeedsAttention,
              let report = operationRecoveryReport else { return nil }

        if report.operationLockUnavailable {
            return "Another Louppe window is still handling an interrupted file operation. Close it, then retry recovery. You can keep reviewing this folder meanwhile."
        }

        let interruptionPrefix = operationRecoveryCause.map {
            $0.hasSuffix(".") ? "\($0) " : "\($0). "
        } ?? ""
        let completedNotice = report.preservedCopies > 0
                || report.preservedMoves > 0
                || report.restoredFiles > 0
                || report.removedPartialCopies > 0
            ? "Other files from the operation were already handled safely. "
            : ""
        if !report.unavailableVolumes.isEmpty {
            let driveNames = report.unavailableVolumes.map { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return name.isEmpty ? path : name
            }
            let drives = driveNames.count == 1
                ? "“\(driveNames[0])”"
                : driveNames.map { "“\($0)”" }.joined(separator: ", ")
            return interruptionPrefix + completedNotice
                + "Some interrupted files are still untouched because "
                + (driveNames.count == 1 ? "a drive is unavailable. " : "drives are unavailable. ")
                + "Reconnect \(drives), then retry recovery. You can keep reviewing this folder meanwhile."
        }

        let count = max(report.unresolvedFiles, 1)
        let message = interruptionPrefix + completedNotice
            + "Louppe couldn't finish checking \(count) interrupted file"
            + (count == 1 ? ". " : "s. ")
            + "It left anything uncertain untouched. You can keep reviewing; Copy, Move, and Clean Up are paused until recovery finishes."
        return message
    }
    /// A sheet, popover, confirmation, or recovery alert owns keyboard/menu
    /// input until it is dismissed. All session command surfaces share this
    /// definition so one route cannot mutate state behind another.
    var isSessionCommandPresentationActive: Bool {
        isExportPresented
            || isFilterPresented
            || isSortPresented
            || isClearAllRatingsConfirmationPresented
            || isLegacySessionMigrationConfirmationPresented
            || pendingCleanUp != nil
            || cleanUpError != nil
            || isRecoveringInterruptedOperations
            || operationRecoveryReportRequiresAcknowledgement
    }
    var isCleaningUp: Bool { activeFileOperation == .cleanUp }
    var isCopyingExport: Bool { activeFileOperation == .exportCopy }
    var isMovingExport: Bool { activeFileOperation == .exportMove }
    var isXMPPublicationRunning: Bool {
        switch xmpPublicationState {
        case .preflighting, .publishing, .cancelling:
            return true
        default:
            return false
        }
    }
    private var hasXMPPublicationSessionState: Bool {
        xmpPublicationState != .idle
    }
    var canRate: Bool {
        return !items.isEmpty
            && !isFileOperationRunning
            && !isLegacySessionMigrationConfirmationPresented
    }
    var canExport: Bool {
        !items.isEmpty
            && !isNewFileOperationBlocked
            && !isLegacySessionMigrationConfirmationPresented
    }
    var canCleanUp: Bool {
        !items.isEmpty
            && !isNewFileOperationBlocked
            && !isLegacySessionMigrationConfirmationPresented
    }
    var isExporting: Bool { isCopyingExport || isMovingExport }

    /// Retained for the complete filesystem transaction. This prevents idle
    /// system sleep while Copy, Move, Trash, restore, or recovery is active.
    /// macOS still sleeps when a MacBook lid is explicitly closed, so Copy's
    /// worker separately tolerates a removable source remount after wake.
    private var fileOperationPowerActivity: NSObjectProtocol?
    var isPreventingIdleSystemSleep: Bool {
        fileOperationPowerActivity != nil
    }

    private func updateFileOperationPowerActivity() {
        let shouldPreventSleep = activeFileOperation != nil
            || isXMPPublicationRunning
            || isRecoveringInterruptedOperations
        if shouldPreventSleep, fileOperationPowerActivity == nil {
            fileOperationPowerActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Louppe is safely transferring files or writing metadata"
            )
        } else if !shouldPreventSleep,
                  let activity = fileOperationPowerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            fileOperationPowerActivity = nil
        }
    }

    /// One undo step can hold several photo changes (e.g. "clear all"),
    /// so a single ⌘Z restores the whole batch.
    private enum MetadataDimension {
        case decision
        case stars
        case color
    }
    private struct MetadataChange {
        /// A complete before-image keeps every physical file's metadata
        /// coherent, while `dimension` makes undo restore only the attribute
        /// changed by that action.
        let previous: PhotoFileMetadataSnapshot
    }
    /// A photo removed by Clean Up, with everything needed to bring it back:
    /// its former position in `items` and where each file landed in the Trash.
    private struct RemovedPhoto: Sendable {
        let index: Int
        let item: PhotoItem
        let trashedFiles: [TrashedFile]
    }
    private enum UndoStep {
        case metadata(
            MetadataDimension,
            [MetadataChange],
            previousFileID: String?
        )
        case cleanUp(
            [RemovedPhoto],
            previousItemID: String?,
            previousIndex: Int
        )
    }
    private var undoStack: [UndoStep] = []
    private var saveDebounce: DispatchWorkItem?
    private var saveDeadline: DispatchWorkItem?
    private var saveTrailingGeneration: UInt64 = 0
    private var saveCycleGeneration: UInt64 = 0
    private var pendingPersistenceTask: Task<SessionPersistence.SaveResult, Never>?
    private var pendingPersistenceRequest: SaveRequest?
    private var retrySaveRequest: SaveRequest?
    /// A backup-only success stays manually retryable so its folder sidecar
    /// can be repaired later, but it must never turn Close or Quit into a
    /// requirement: the captured ratings are already durable.
    private var retrySaveIsOptionalSidecarRepair = false
    /// Monotonic within one opened-folder access. A completed older save can
    /// advance durability only through the generation it actually captured;
    /// it can never make a newer rating look clean.
    private var sessionChangeGeneration: UInt64 = 0
    private var durableSessionChangeGeneration: UInt64?
    private var persistenceGenerationAccessID: UUID?
    @Published private(set) var activePersistenceSaveCount = 0
    private var saveRequestedWhilePersistenceBusy = false
    /// Inspectable by focused concurrency tests; production uses the flag only
    /// to coalesce repeated maximum-age checkpoints behind one active write.
    var hasDeferredPersistenceSave: Bool {
        saveRequestedWhilePersistenceBusy
    }

    /// Deterministic test barrier for completion observers that run separately
    /// from a caller awaiting one specific persistence task.
    @discardableResult
    func waitForPersistenceIdleForTesting(
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while activePersistenceSaveCount > 0
            || saveRequestedWhilePersistenceBusy {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }
    private var filterDebounce: DispatchWorkItem?
    private var prefetchDebounce: DispatchWorkItem?
    private var scanTask: Task<Void, Never>?
    private let persistence: any SessionPersistenceClient
    private let saveTrailingDelay: TimeInterval
    private let saveMaximumDelay: TimeInterval
    /// Nil selects the production Application Support journal directory.
    /// Tests can inject a disposable root and must explicitly opt into launch
    /// recovery, so constructing a view-model can never touch live user files.
    private let operationJournalDirectory: URL?
    private var saveSequence: UInt64 = 0
    private var latestReportedSaveSequence: UInt64 = 0
    private var persistenceAccess: SessionPersistence.AccessContext?
    private var scanGeneration: UInt64 = 0
    private var folderOpenGeneration: UInt64 = 0
    private var cleanUpGeneration: UInt64 = 0
    private var xmpPublicationGeneration: UInt64 = 0
    private var xmpPublicationCancelFlag: XMPPublicationCancelFlag?
    private var xmpPublicationTask: Task<Void, Never>?
    private struct XMPPublicationSessionToken: Equatable {
        let generation: UInt64
        let scanGeneration: UInt64
        let folder: URL?
    }
    private var xmpPublicationSessionToken: XMPPublicationSessionToken?
    private var deferredFolderOpen: URL?
    /// The session affected by an interrupted mutation. Both the exact path
    /// bytes and stable directory identity must still match before a delayed
    /// rescan can touch the current session.
    private struct RecoveryRescanTarget {
        let folder: URL
        let identity: SessionPersistence.SourceFolderIdentity
    }
    private var recoveryRescanTarget: RecoveryRescanTarget?
    private var preparedIndex = PreparedSessionIndex()
    private struct ScanResumeIdentity {
        let folder: URL
        let currentItemID: String?
        let selectedItemIDs: Set<String>
    }
    private var scanResumeIdentity: ScanResumeIdentity?
    private var ratingTally = (yes: 0, no: 0, undecided: 0)
    private var mixedRatingCount = 0
    private var starTally: [StarRating: Int] = [:]
    private var unratedStarCountStorage = 0
    private var mixedStarCountStorage = 0
    private var colorTally: [PhotoColorLabel: Int] = [:]
    private var noColorCountStorage = 0
    private var mixedColorCountStorage = 0
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

    init(
        persistence: any SessionPersistenceClient = SessionPersistence(),
        saveTrailingDelay: TimeInterval = 0.5,
        saveMaximumDelay: TimeInterval = 5,
        operationJournalDirectory: URL? = nil,
        automaticallyRecoversInterruptedOperations: Bool = false
    ) {
        self.persistence = persistence
        self.saveTrailingDelay = max(0, saveTrailingDelay)
        // These clocks are independent: production normally uses a longer
        // maximum dirty age, while tests deliberately put the hard deadline
        // first to prove it is not just the trailing debounce firing.
        self.saveMaximumDelay = max(0, saveMaximumDelay)
        self.operationJournalDirectory = operationJournalDirectory
        loadRecents()
        if automaticallyRecoversInterruptedOperations,
           FileOperationJournal.hasPendingOperations(
            directory: operationJournalDirectory
           ) {
            beginInterruptedOperationRecovery()
        }
    }

    // MARK: - Interrupted file-operation recovery

    /// Retries every still-active journal. Existing files are never
    /// overwritten; an unavailable volume or identity mismatch remains
    /// visible for another retry instead of being guessed around.
    var canRetryInterruptedOperationRecovery: Bool {
        recoveryNeedsAttention && !isFileOperationRunning
    }
    var canKeepInterruptedFilesAsTheyAre: Bool {
        recoveryNeedsAttention && !isFileOperationRunning
    }

    func retryInterruptedOperationRecovery() {
        guard canRetryInterruptedOperationRecovery else { return }
        // The user may have opened the affected folder while the warning was
        // nonmodal. Capture its exact identity so any files restored by this
        // retry become visible through a safe same-folder rescan.
        beginInterruptedOperationRecovery(rescanOnSuccess: sourceFolder != nil)
    }

    /// Explicitly discard only Louppe's recovery bookkeeping. Media stays at
    /// its current paths, so a permanently ambiguous record cannot disable
    /// future Copy, Move, or Clean Up actions forever.
    func keepInterruptedFilesAsTheyAre() {
        guard canKeepInterruptedFilesAsTheyAre else { return }
        captureRecoveryRescanTargetForCurrentFolder()
        operationRecoveryReport = nil
        recoveryNeedsAttention = false
        isRecoveringInterruptedOperations = true

        let journalDirectory = operationJournalDirectory
        let worker = Task.detached(priority: .userInitiated) {
            FileOperationJournal.keepFilesAsTheyAreAndForgetPendingOperations(
                directory: journalDirectory
            )
        }
        Task { @MainActor [weak self] in
            let report = await worker.value
            guard let self else { return }
            self.isRecoveringInterruptedOperations = false
            let needsAttention = Self.recoveryReportNeedsAttention(report)
            self.recoveryNeedsAttention = needsAttention
            self.operationRecoveryReport = needsAttention ? report : nil
            let rescanTarget = self.recoveryRescanTarget
            if !needsAttention {
                self.operationRecoveryCause = nil
                self.recoveryRescanTarget = nil
            }

            let deferredFolder = self.deferredFolderOpen
            self.deferredFolderOpen = nil
            if let deferredFolder {
                self.openFolder(deferredFolder)
            } else if let rescanTarget,
                      self.recoveryRescanTargetMatchesCurrentSession(
                        rescanTarget
                      ) {
                self.rescan()
            }
        }
    }

    func dismissOperationRecoveryReport() {
        operationRecoveryReport = nil
        operationRecoveryCause = nil
    }

    private func beginInterruptedOperationRecovery(
        rescanOnSuccess: Bool = false
    ) {
        guard !isFileOperationRunning else { return }
        if rescanOnSuccess {
            captureRecoveryRescanTargetForCurrentFolder()
        }
        operationRecoveryReport = nil
        recoveryNeedsAttention = false
        isRecoveringInterruptedOperations = true

        let journalDirectory = operationJournalDirectory
        let worker = Task.detached(priority: .userInitiated) {
            FileOperationJournal.recoverPendingOperations(
                directory: journalDirectory
            )
        }
        Task { @MainActor [weak self] in
            let report = await worker.value
            guard let self else { return }
            self.isRecoveringInterruptedOperations = false
            let needsAttention = Self.recoveryReportNeedsAttention(report)
            self.recoveryNeedsAttention = needsAttention
            let changedFiles = report.preservedCopies > 0
                || report.preservedMoves > 0
                || report.restoredFiles > 0
                || report.removedPartialCopies > 0
            self.operationRecoveryReport = needsAttention || changedFiles
                ? report
                : nil
            if !needsAttention, !changedFiles {
                self.operationRecoveryCause = nil
            }

            let deferredFolder = self.deferredFolderOpen
            self.deferredFolderOpen = nil
            let rescanTarget = self.recoveryRescanTarget
            if !needsAttention {
                self.recoveryRescanTarget = nil
            }
            if let deferredFolder {
                self.openFolder(deferredFolder)
            } else if let rescanTarget,
                      self.recoveryRescanTargetMatchesCurrentSession(
                        rescanTarget
                      ) {
                self.rescan()
            }
        }
    }

    private func captureRecoveryRescanTargetForCurrentFolder() {
        // A retry can happen after the user switches folders. Never retain a
        // target captured for an earlier session when the current folder has
        // gone away or can no longer be identified.
        recoveryRescanTarget = nil
        guard let folder = sourceFolder,
           let identity = persistenceAccess?.folderIdentity
                ?? (try? SessionPersistence.SourceFolderIdentity.capture(
                    at: folder
                )) else {
            return
        }
        recoveryRescanTarget = RecoveryRescanTarget(
            folder: folder,
            identity: identity
        )
    }

    private static func recoveryReportNeedsAttention(
        _ report: FileOperationJournal.RecoveryReport
    ) -> Bool {
        report.operationLockUnavailable || report.hasUnresolvedFiles
    }

    private func recoveryRescanTargetMatchesCurrentSession(
        _ target: RecoveryRescanTarget
    ) -> Bool {
        guard let folder = sourceFolder,
              FileOperationJournal.exactPathsEqual(folder, target.folder)
        else { return false }
        return target.identity.matches(folder: folder)
    }

#if DEBUG
    /// Gives model-focused tests the same derived-data boundary as a completed
    /// folder scan without requiring filesystem setup.
    func rebuildDerivedDataForTesting() {
        rebuildDerivedData()
        applyFilter()
    }

    /// Deterministic recovery-state setup for command-gating tests. Production
    /// reaches the same state only through the journal worker above.
    func presentOperationRecoveryReportForTesting(
        _ report: FileOperationJournal.RecoveryReport?,
        cause: String? = nil
    ) {
        operationRecoveryReport = report
        operationRecoveryCause = cause
        recoveryNeedsAttention = report.map(Self.recoveryReportNeedsAttention)
            ?? false
    }

    /// Places a Clean Up restore below later rating steps so tests can prove
    /// an unavailable restore is retained instead of accidentally popped.
    func pushCleanUpUndoForTesting() {
        pushUndo(.cleanUp(
            [],
            previousItemID: currentItemID,
            previousIndex: currentIndex
        ))
    }
#endif

    // MARK: - Counts

    var yesCount: Int { ratingTally.yes }
    var noCount: Int { ratingTally.no }
    var undecidedCount: Int { ratingTally.undecided }
    /// Mixed decisions remain part of the legacy/export Undecided total, but
    /// the normal Filter exposes both buckets independently.
    var plainUndecidedCount: Int { max(0, ratingTally.undecided - mixedRatingCount) }
    var mixedCount: Int { mixedRatingCount }
    var ratedCount: Int { ratingTally.yes + ratingTally.no + mixedRatingCount }
    func starCount(_ rating: StarRating) -> Int { starTally[rating, default: 0] }
    var unratedStarCount: Int { unratedStarCountStorage }
    var mixedStarCount: Int { mixedStarCountStorage }
    func colorCount(_ label: PhotoColorLabel) -> Int { colorTally[label, default: 0] }
    var noColorCount: Int { noColorCountStorage }
    var mixedColorCount: Int { mixedColorCountStorage }

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

    /// Review metadata is lock-backed and therefore does not replace the
    /// `PhotoItem` value. Refresh only a prepared sort/filter that depends on
    /// the changed dimension, then publish the new scalar snapshot to tiles.
    private func publishMetadataMutation(_ dimension: MetadataDimension) {
        let changesSort: Bool
        let changesFilter: Bool
        switch dimension {
        case .decision:
            changesSort = sort.key == .decision
            changesFilter = !filter.excludedDecisionStates.isEmpty
        case .stars:
            changesSort = sort.key == .starRating
            changesFilter = !filter.excludedStarStates.isEmpty
        case .color:
            changesSort = sort.key == .colorLabel
            changesFilter = !filter.excludedColorStates.isEmpty
        }
        if changesSort {
            preparedIndex.rebuildSort(items, sort: sort)
        }
        if changesSort || changesFilter {
            applyFilter()
        }
        objectWillChange.send()
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
        var stars: [StarRating: Int] = [:]
        var unratedStars = 0
        var mixedStars = 0
        var colors: [PhotoColorLabel: Int] = [:]
        var noColor = 0
        var mixedColors = 0
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
            let metadata = item.metadataState
            // Keep the three public counts exhaustive: mixed pairs are
            // unresolved and therefore included in `undecidedCount`.
            switch metadata.decision {
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
            switch metadata.stars {
            case .unrated: unratedStars += 1
            case .stars(let rating): stars[rating, default: 0] += 1
            case .mixed: mixedStars += 1
            }
            switch metadata.color {
            case .none: noColor += 1
            case .label(let label): colors[label, default: 0] += 1
            case .mixed: mixedColors += 1
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
        starTally = stars
        unratedStarCountStorage = unratedStars
        mixedStarCountStorage = mixedStars
        colorTally = colors
        noColorCountStorage = noColor
        mixedColorCountStorage = mixedColors
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
        if let activeID = videoPlayback.itemID,
           let activeItem = items.first(where: { $0.id == activeID }) {
            if !videoPlayback.represents(activeItem) {
                videoPlayback.stop()
            }
        } else if videoPlayback.itemID != nil {
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
        starTally = [:]
        unratedStarCountStorage = 0
        mixedStarCountStorage = 0
        colorTally = [:]
        noColorCountStorage = 0
        mixedColorCountStorage = 0
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
        if isRecoveringInterruptedOperations {
            deferredFolderOpen = url
            return
        }
        if hasXMPPublicationSessionState {
            guard !isSessionTransitioning,
                  activeFileOperation == nil,
                  !isPreparingForTermination else { return }
            isSessionTransitioning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cancelAndAwaitXMPPublication()
                self.isExportPresented = false
                self.isSessionTransitioning = false
                self.openFolder(url)
            }
            return
        }
        guard !isFileOperationRunning else { return }
        folderOpenGeneration &+= 1
        let openGeneration = folderOpenGeneration
        if let currentFolder = sourceFolder,
           case .ready = phase {
            isSessionTransitioning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self
                    .persistCurrentSessionIfNeededBeforeDiscard()
                guard self.folderOpenGeneration == openGeneration else { return }
                self.isSessionTransitioning = false
                guard result?.canDiscardInMemoryState != false,
                      self.sourceFolder?.standardizedFileURL
                        == currentFolder.standardizedFileURL else { return }
                self.beginOpeningFolder(url)
            }
            return
        }
        beginOpeningFolder(url)
    }

    private func beginOpeningFolder(_ url: URL) {
        cancelScheduledSave()
        persistenceGenerationAccessID = nil
        durableSessionChangeGeneration = nil
        sessionChangeGeneration = 0
        isLegacySessionMigrationConfirmationPresented = false
        legacySessionMigrationMissingFileCount = 0
        legacySessionMigrationUsesUnownedBackup = false
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
        // Every scan establishes a fresh identity/revision access. A retained
        // backup-only Retry belongs to the access being replaced; keeping it
        // through a failed same-folder rescan leaves a visible button whose
        // result can no longer be applied. The new scan/save will recreate a
        // current warning and Retry if the sidecar still needs repair.
        persistenceWarning = nil
        persistenceRejectedInvalidSnapshot = false
        retrySaveRequest = nil
        retrySaveIsOptionalSidecarRepair = false
        persistenceAccess = nil
        if !isSameFolder {
            retainedMissingSessionEntries = []
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
        emptySessionReason = nil
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
                let folderIdentity = try SessionPersistence.SourceFolderIdentity
                    .capture(at: url)
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
                guard folderIdentity.matches(folder: url) else {
                    throw FolderScanner.ScanError.filesChangedDuringScan
                }
                let savedSession = await self.persistence.read(
                    for: url,
                    folderIdentity: folderIdentity
                )
                try FolderScanner.validateScannedIdentities(scanned)
                guard folderIdentity.matches(folder: url) else {
                    throw FolderScanner.ScanError.filesChangedDuringScan
                }
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
        emptySessionReason = nil
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
            retainedMissingSessionEntries = []
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
        persistenceRejectedInvalidSnapshot = false
        guard let access = persistenceResult.access else {
            items = []
            resetDerivedData()
            visibleIndices = []
            phase = .welcome
            scanError = "Louppe couldn't establish a safe session-writing context for this folder. Nothing was saved; open it again."
            return
        }
        persistenceAccess = access
        persistenceGenerationAccessID = access.id
        // The freshly read/scanned state is the discard-safe baseline. Its
        // automatic sidecar creation, repair, or schema refresh is optional;
        // only later user/session changes advance beyond this generation.
        durableSessionChangeGeneration = 0
        sessionChangeGeneration = 0
        let loaded = scanned
        // Restore prior ratings from the sidecar file, if present.
        var pendingIdentityConflicts: [(
            persistedFileIDBytes: Data,
            displayName: String
        )] = []
        var consumedPersistedFileIDs = Set<Data>()
        var relocatedSessionNeedsIdentityProof = false
        var unmatchedLegacyPhysicalFileCount = 0
        var legacySessionNeedsConfirmation = false
        if let session = persistenceResult.session {
            let ratingIndex = SessionRatingIndex(session: session)
            for i in loaded.indices {
                for file in loaded[i].individualFiles {
                    switch ratingIndex.lookup(for: file) {
                    case .match(let match):
                        consumedPersistedFileIDs.insert(
                            match.persistedFileIDBytes
                        )
                        loaded[i].restoreMetadata(
                            PhotoFileMetadataSnapshot(
                                fileID: file.id,
                                rating: match.value.rating,
                                ratedAt: match.value.ratedAt,
                                starRating: match.value.starRating,
                                starsChangedAt: match.value.starsChangedAt,
                                colorLabel: match.value.colorLabel,
                                colorChangedAt: match.value.colorChangedAt
                            )
                        )
                    case .identityConflict(let conflict):
                        pendingIdentityConflicts.append((
                            persistedFileIDBytes:
                                conflict.persistedFileIDBytes,
                            displayName: file.displayName
                        ))
                    case .absent:
                        break
                    }
                }
            }
            if session.version >= 4,
               session.fileIDEncoding == .percentEncodedFileSystemPath {
                retainedMissingSessionEntries = session.entries.filter {
                    !consumedPersistedFileIDs.contains(
                        Data($0.filename.utf8)
                    )
                }
            } else {
                retainedMissingSessionEntries = []
                unmatchedLegacyPhysicalFileCount = ratingIndex
                    .persistedPhysicalFileIDBytes
                    .subtracting(consumedPersistedFileIDs)
                    .count
            }
            legacySessionNeedsConfirmation = session.version < 4
                && (unmatchedLegacyPhysicalFileCount > 0
                    || persistenceResult.requiresPhysicalIdentityProof)
            let recordedFolder = URL(fileURLWithPath: session.sourcePath)
                .resolvingSymlinksInPath().standardizedFileURL
            let openedFolder = url.resolvingSymlinksInPath()
                .standardizedFileURL
            relocatedSessionNeedsIdentityProof =
                (recordedFolder.path != openedFolder.path
                    || (persistenceResult.requiresPhysicalIdentityProof
                        && session.version >= 4))
                && !session.entries.isEmpty
                && consumedPersistedFileIDs.isEmpty
        } else {
            retainedMissingSessionEntries = []
        }
        let identityConflicts = pendingIdentityConflicts.compactMap {
            consumedPersistedFileIDs.contains($0.persistedFileIDBytes)
                ? nil
                : $0.displayName
        }
        if !identityConflicts.isEmpty {
            items = []
            resetDerivedData()
            visibleIndices = []
            phase = .welcome
            let count = identityConflicts.count
            let examples = identityConflicts.prefix(3).joined(separator: ", ")
            let exampleText = examples.isEmpty ? "" : " (\(examples))"
            scanError = "Louppe found \(count) photo"
                + (count == 1 ? " or video" : "s or videos")
                + " with the same name as saved session entries, but not the same physical file"
                + exampleText + ". The existing ratings were left untouched. Restore the original "
                + (count == 1 ? "file" : "files")
                + ", or rename the replacement so it no longer uses the original filename, then open the folder again. Louppe will retain the saved decision for the missing original."
            return
        }
        if relocatedSessionNeedsIdentityProof {
            items = []
            resetDerivedData()
            visibleIndices = []
            phase = .welcome
            scanError = "This folder contains a session from another location, but Louppe couldn't verify any of its exact original files here. The ratings were left untouched so they cannot be applied to a copied or unrelated folder."
            return
        }
        items = loaded
        emptySessionReason = nil
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
        } else if legacySessionNeedsConfirmation {
            persistenceWarning = persistenceResult.recoveryMessage
            legacySessionMigrationMissingFileCount =
                unmatchedLegacyPhysicalFileCount
            legacySessionMigrationUsesUnownedBackup =
                persistenceResult.requiresPhysicalIdentityProof
            isLegacySessionMigrationConfirmationPresented = true
        } else {
            persistenceWarning = persistenceResult.recoveryMessage
            saveSession()
        }
    }

    /// Accept the exact filename matches from a legacy snapshot and persist
    /// their first physical-identity-bound schema-4 checkpoint.
    func confirmLegacySessionMigration() {
        guard isLegacySessionMigrationConfirmationPresented,
              case .ready = phase,
              sourceFolder != nil else { return }
        isLegacySessionMigrationConfirmationPresented = false
        legacySessionMigrationMissingFileCount = 0
        legacySessionMigrationUsesUnownedBackup = false
        // Forgetting absent legacy entries is an explicit session change, not
        // optional maintenance of the just-opened baseline.
        markSessionChanged()
        saveSession()
    }

    /// Leave the legacy sidecar and backup byte-for-byte untouched.
    func closeLegacySessionWithoutMigrating() {
        guard isLegacySessionMigrationConfirmationPresented else { return }
        isLegacySessionMigrationConfirmationPresented = false
        legacySessionMigrationMissingFileCount = 0
        legacySessionMigrationUsesUnownedBackup = false
        finishClosingSession()
    }

#if DEBUG
    /// Focused key-routing tests use an ordinary in-memory ready session and
    /// need to exercise the same modal command gate as the real scan flow.
    func presentLegacySessionMigrationConfirmationForTesting() {
        guard case .ready = phase else { return }
        isLegacySessionMigrationConfirmationPresented = true
    }
#endif

    /// Re-scan the current folder to pick up newly added photos.
    /// Existing ratings survive: they're saved to the sidecar first,
    /// and the scan restores them by filename.
    func rescan() {
        if hasXMPPublicationSessionState {
            guard !isSessionTransitioning,
                  activeFileOperation == nil,
                  !isPreparingForTermination else { return }
            isSessionTransitioning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cancelAndAwaitXMPPublication()
                self.isExportPresented = false
                self.isSessionTransitioning = false
                self.rescan()
            }
            return
        }
        guard !isFileOperationRunning, let folder = sourceFolder else { return }
        isSessionTransitioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self
                .persistCurrentSessionIfNeededBeforeDiscard()
            self.isSessionTransitioning = false
            guard result?.canDiscardInMemoryState != false else { return }
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

    var effectiveDecisionState: PhotoItemRatingState {
        let states = effectiveSelection.sorted().compactMap {
            items.indices.contains($0) ? items[$0].ratingState : nil
        }
        guard let first = states.first else { return .undecided }
        return states.dropFirst().allSatisfy { $0 == first } ? first : .mixed
    }

    var effectiveStarRatingState: PhotoItemStarRatingState {
        let states = effectiveSelection.sorted().compactMap {
            items.indices.contains($0) ? items[$0].starRatingState : nil
        }
        guard let first = states.first else { return .unrated }
        return states.dropFirst().allSatisfy { $0 == first } ? first : .mixed
    }

    var effectiveColorLabelState: PhotoItemColorLabelState {
        let states = effectiveSelection.sorted().compactMap {
            items.indices.contains($0) ? items[$0].colorLabelState : nil
        }
        guard let first = states.first else { return .none }
        return states.dropFirst().allSatisfy { $0 == first } ? first : .mixed
    }

    func clearSelection() {
        setSelectionIndices([])
    }

    /// Routes a thumbnail click by modifier key — shared by the Browser and
    /// Grid views so both respond identically. `plainClick` runs when no
    /// modifier is held; both views use it to make the clicked photo current.
    func handleThumbnailClick(
        at index: Int,
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
        plainClick: () -> Void
    ) {
        guard !isFileOperationRunning else { return }
        if modifiers.contains(.shift) {
            selectRange(to: index)
        } else if modifiers.contains(.command) {
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
        guard canRate else { return }
        applyRating(rating, to: effectiveSelection.sorted())
        setSelectionIndices([])
        advanceToNextUndecided()
    }

    /// Grid rating-control click: cycle the clicked photo's rating. Using the
    /// control on a photo that's part of a multi-selection gives the whole
    /// selection the clicked photo's next rating in one undoable step; the
    /// selection stays so the user can keep cycling.
    func toggleRating(at index: Int) {
        guard canRate else { return }
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
        guard canRate else { return }
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
            items[index].metadataSnapshots.map { MetadataChange(previous: $0) }
        }
        pushUndo(.metadata(.decision, changes, previousFileID: currentItemID))
        let now = Date()
        // Ratings live in shared lock-backed storage whose reference identity
        // does not change. Update it first, then publish once so lazy Browser
        // and Grid rows cannot redraw the old snapshot and miss the mutation.
        for index in valid {
            let previousState = items[index].ratingState
            items[index].setRating(rating, ratedAt: now)
            transitionRatingCount(
                from: previousState,
                to: items[index].ratingState
            )
        }
        publishMetadataMutation(.decision)
        scheduleSave()
    }

    private func setRating(_ rating: Rating, atIndex index: Int, recordUndo: Bool) {
        guard items.indices.contains(index) else { return }
        if recordUndo {
            let changes = items[index].metadataSnapshots.map {
                MetadataChange(previous: $0)
            }
            pushUndo(.metadata(.decision, changes, previousFileID: currentItemID))
        }
        let previousState = items[index].ratingState
        items[index].setRating(rating, ratedAt: Date())
        transitionRatingCount(
            from: previousState,
            to: items[index].ratingState
        )
        publishMetadataMutation(.decision)
        scheduleSave()
    }

    /// Applies stars independently of the Yes/No decision. Numeric shortcuts
    /// and the Info panel use this batch-aware entry point and never advance.
    func setStarRating(_ rating: StarRating?) {
        guard canRate else { return }
        applyStarRating(rating, to: effectiveSelection.sorted())
    }

    func setStarRating(_ rating: StarRating?, at index: Int) {
        guard canRate, items.indices.contains(index) else { return }
        let targets = selectedIndices.count > 1 && selectedIndices.contains(index)
            ? selectedIndices.sorted()
            : [index]
        applyStarRating(rating, to: targets)
    }

    private func applyStarRating(_ rating: StarRating?, to targets: [Int]) {
        let valid = targets.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let changes = valid.flatMap { index in
            items[index].metadataSnapshots.map { MetadataChange(previous: $0) }
        }
        pushUndo(.metadata(.stars, changes, previousFileID: currentItemID))
        let now = Date()
        for index in valid {
            let previousState = items[index].starRatingState
            items[index].setStars(rating, changedAt: now)
            transitionStarCount(from: previousState, to: items[index].starRatingState)
        }
        publishMetadataMutation(.stars)
        scheduleSave()
    }

    /// Applies a color label independently of decision and stars.
    func setColorLabel(_ label: PhotoColorLabel?) {
        guard canRate else { return }
        applyColorLabel(label, to: effectiveSelection.sorted())
    }

    func setColorLabel(_ label: PhotoColorLabel?, at index: Int) {
        guard canRate, items.indices.contains(index) else { return }
        let targets = selectedIndices.count > 1 && selectedIndices.contains(index)
            ? selectedIndices.sorted()
            : [index]
        applyColorLabel(label, to: targets)
    }

    private func applyColorLabel(_ label: PhotoColorLabel?, to targets: [Int]) {
        let valid = targets.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let changes = valid.flatMap { index in
            items[index].metadataSnapshots.map { MetadataChange(previous: $0) }
        }
        pushUndo(.metadata(.color, changes, previousFileID: currentItemID))
        let now = Date()
        for index in valid {
            let previousState = items[index].colorLabelState
            items[index].setColor(label, changedAt: now)
            transitionColorCount(from: previousState, to: items[index].colorLabelState)
        }
        publishMetadataMutation(.color)
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
        let changes = items.flatMap { item -> [MetadataChange] in
            guard item.hasAnyRating else { return [] }
            return item.metadataSnapshots.compactMap {
                guard $0.rating != .undecided else { return nil }
                return MetadataChange(previous: $0)
            }
        }
        guard !changes.isEmpty else { return }
        pushUndo(.metadata(.decision, changes, previousFileID: currentItemID))
        for item in items {
            item.setRating(.undecided, ratedAt: nil)
        }
        ratingTally = (0, 0, items.count)
        mixedRatingCount = 0
        publishMetadataMutation(.decision)
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

    private func transitionStarCount(
        from old: PhotoItemStarRatingState,
        to new: PhotoItemStarRatingState
    ) {
        guard old != new else { return }
        adjustStarCount(for: old, by: -1)
        adjustStarCount(for: new, by: 1)
    }

    private func adjustStarCount(for state: PhotoItemStarRatingState, by amount: Int) {
        switch state {
        case .unrated: unratedStarCountStorage += amount
        case .stars(let rating): starTally[rating, default: 0] += amount
        case .mixed: mixedStarCountStorage += amount
        }
    }

    private func transitionColorCount(
        from old: PhotoItemColorLabelState,
        to new: PhotoItemColorLabelState
    ) {
        guard old != new else { return }
        adjustColorCount(for: old, by: -1)
        adjustColorCount(for: new, by: 1)
    }

    private func adjustColorCount(for state: PhotoItemColorLabelState, by amount: Int) {
        switch state {
        case .none: noColorCountStorage += amount
        case .label(let label): colorTally[label, default: 0] += amount
        case .mixed: mixedColorCountStorage += amount
        }
    }

    /// Whether ⌘Z has anything to undo — drives the toolbar button's state.
    /// (Not @Published, but every undo-stack change happens alongside a
    /// published mutation, so views re-evaluate it at the right moments.)
    var canUndo: Bool {
        guard !isFileOperationRunning,
              let step = undoStack.last else { return false }
        if case .cleanUp = step {
            return !recoveryNeedsAttention
        }
        return true
    }

    private func pushUndo(_ step: UndoStep) {
        undoStack.append(step)
        if undoStack.count > 500 { undoStack.removeFirst() }
    }

    func undo() {
        guard canUndo, let step = undoStack.last else { return }
        // Inspect before popping: unresolved recovery blocks only a Clean Up
        // restore. The step must remain available for a later retry, while a
        // newer rating step above it can still be undone immediately.
        if case .cleanUp = step, recoveryNeedsAttention { return }
        _ = undoStack.popLast()
        // Undo moves the session back in time; a live selection would no
        // longer mean what the user built it for.
        setSelectionIndices([])
        switch step {
        case .metadata(let dimension, let changes, let previousFileID):
            let indexedChanges: [(index: Int, change: MetadataChange)] =
                changes.compactMap { change in
                    guard let index = itemIndexByFileID[change.previous.fileID],
                          items.indices.contains(index) else { return nil }
                    return (index: index, change: change)
                }
            var previousDecisionStates: [Int: PhotoItemRatingState] = [:]
            var previousStarStates: [Int: PhotoItemStarRatingState] = [:]
            var previousColorStates: [Int: PhotoItemColorLabelState] = [:]
            for (index, _) in indexedChanges {
                previousDecisionStates[index] = items[index].ratingState
                previousStarStates[index] = items[index].starRatingState
                previousColorStates[index] = items[index].colorLabelState
            }
            for (index, change) in indexedChanges {
                switch dimension {
                case .decision: items[index].restoreRating(change.previous)
                case .stars: items[index].restoreStars(change.previous)
                case .color: items[index].restoreColor(change.previous)
                }
            }
            for (index, previousState) in previousDecisionStates {
                switch dimension {
                case .decision:
                    transitionRatingCount(from: previousState, to: items[index].ratingState)
                case .stars:
                    if let old = previousStarStates[index] {
                        transitionStarCount(from: old, to: items[index].starRatingState)
                    }
                case .color:
                    if let old = previousColorStates[index] {
                        transitionColorCount(from: old, to: items[index].colorLabelState)
                    }
                }
            }
            restoreCurrentFile(
                fileID: previousFileID,
                fallbackIndex: currentIndex
            )
            if !indexedChanges.isEmpty {
                publishMetadataMutation(dimension)
            }
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

    func presentExport() {
        guard canExport else { return }
        isExportPresented = true
    }

    /// Flushes a pending search debounce before presenting counts, ensuring
    /// the confirmation describes the exact set that will be moved.
    func requestCleanUp(_ mode: CleanUpMode) {
        guard canCleanUp else { return }
        flushPendingFilter()
        guard hasCleanUpTargets(for: mode) else { return }
        pendingCleanUp = mode
    }

    /// Moves every photo the mode rejects within the chosen scope to the
    /// macOS Trash — never a permanent delete. One ⌘Z brings the whole batch
    /// back. A photo is only removed if *all* its files could be trashed; on a
    /// partial failure its already-trashed files are put back. If that
    /// rollback also fails, the app reports the inconsistent pair explicitly.
    func performCleanUp(_ mode: CleanUpMode) {
        guard !isNewFileOperationBlocked else { return }
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
        videoPlayback.stop()
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
            emptySessionReason = items.isEmpty ? .trashedUndoable : nil
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
            markSessionChanged()
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
                message += " Louppe's file-safety checks stopped the operation before another file was touched."
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
        guard !isNewFileOperationBlocked else { return }
        let snapshots = removed.map {
            TrashedPhotoSnapshot(index: $0.index, item: $0.item, files: $0.trashedFiles)
        }
        cleanUpGeneration &+= 1
        let generation = cleanUpGeneration
        videoPlayback.stop()
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
        emptySessionReason = items.isEmpty
            ? .unavailableAfterFailedRestore
            : nil
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
                cleanUpError? += " Louppe's file-safety checks stopped the operation before another file was touched."
            }
        }
        rebuildDerivedData()
        restoreCurrentItem(
            itemID: previousItemID,
            fallbackIndex: previousIndex
        )
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        markSessionChanged()
        saveSession()
        activeFileOperation = nil
        cleanUpProgress = nil
    }

    // MARK: - Export

    func prepareXMPPublication(
        selected: [PhotoItem],
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool = false
    ) {
        guard !selected.isEmpty,
              !isNewFileOperationBlocked,
              case .idle = xmpPublicationState,
              case .ready = phase else { return }
        let input: XMPPublicationInput
        do {
            // Capture every physical file's complete metadata once on the
            // session actor. Later rating changes cannot alter this plan.
            input = try XMPPublicationInput(
                items: selected,
                familyContextItems: items,
                profile: profile,
                visibleDecisionKeywords: visibleDecisionKeywords,
                allowExternalLabelReplacement: allowExternalLabelReplacement
            )
        } catch {
            xmpPublicationState = .failed(error.localizedDescription)
            return
        }

        xmpPublicationGeneration &+= 1
        let token = XMPPublicationSessionToken(
            generation: xmpPublicationGeneration,
            scanGeneration: scanGeneration,
            folder: sourceFolder
        )
        let cancelFlag = XMPPublicationCancelFlag()
        xmpPublicationSessionToken = token
        xmpPublicationCancelFlag = cancelFlag
        xmpPublicationState = .preflighting(
            done: 0,
            total: input.selectedMediaPaths.count
        )
        let progress: XMPPublicationPlanner.Progress = { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self,
                      self.xmpPublicationSessionToken == token,
                      case .preflighting = self.xmpPublicationState else { return }
                self.xmpPublicationState = .preflighting(done: done, total: total)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            await XMPPublicationPlanner.preflight(
                input,
                isCancelled: { cancelFlag.isSet },
                progress: progress
            )
        }
        xmpPublicationTask = Task { @MainActor [weak self] in
            let plan = await worker.value
            guard let self,
                  self.xmpPublicationSessionToken == token else { return }
            self.xmpPublicationTask = nil
            self.xmpPublicationCancelFlag = nil
            guard self.matchesCurrentSession(token) else {
                self.finishXMPPublicationLifecycle()
                return
            }
            if let plan {
                self.xmpPublicationState = .awaitingConfirmation(plan)
            } else {
                self.finishXMPPublicationLifecycle()
            }
        }
    }

    func startXMPPublication(planID: UUID) {
        guard !isNewFileOperationBlocked,
              case .awaitingConfirmation(let plan) = xmpPublicationState,
              plan.id == planID,
              case .ready = phase else { return }
        xmpPublicationGeneration &+= 1
        let token = XMPPublicationSessionToken(
            generation: xmpPublicationGeneration,
            scanGeneration: scanGeneration,
            folder: sourceFolder
        )
        let cancelFlag = XMPPublicationCancelFlag()
        xmpPublicationSessionToken = token
        xmpPublicationCancelFlag = cancelFlag
        xmpPublicationState = .publishing(done: 0, total: plan.publishableCount)
        let progress: XMPPublicationWorker.Progress = { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self,
                      self.xmpPublicationSessionToken == token,
                      case .publishing = self.xmpPublicationState else { return }
                self.xmpPublicationState = .publishing(done: done, total: total)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            await XMPPublicationWorker.publish(
                plan,
                cancelFlag: cancelFlag,
                progress: progress
            )
        }
        xmpPublicationTask = Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self,
                  self.xmpPublicationSessionToken == token else { return }
            self.xmpPublicationTask = nil
            self.xmpPublicationCancelFlag = nil
            guard self.matchesCurrentSession(token) else {
                self.finishXMPPublicationLifecycle()
                return
            }
            self.xmpPublicationState = .finished(result)
        }
    }

    func cancelXMPPublication() {
        switch xmpPublicationState {
        case .preflighting, .publishing:
            xmpPublicationCancelFlag?.set()
            xmpPublicationState = .cancelling
        case .awaitingConfirmation, .finished, .failed:
            finishXMPPublicationLifecycle()
        case .idle, .cancelling:
            break
        }
    }

    func resetXMPPublication() {
        guard !isXMPPublicationRunning else { return }
        finishXMPPublicationLifecycle()
    }

    /// Folder transitions and Quit call this before changing session
    /// identity. A requested cancellation waits until an in-progress atomic
    /// replacement has either committed or rolled back its private temporary.
    func cancelAndAwaitXMPPublication() async {
        xmpPublicationCancelFlag?.set()
        if isXMPPublicationRunning {
            xmpPublicationState = .cancelling
        }
        let task = xmpPublicationTask
        await task?.value
        finishXMPPublicationLifecycle()
    }

    private func matchesCurrentSession(
        _ token: XMPPublicationSessionToken
    ) -> Bool {
        token.scanGeneration == scanGeneration
            && token.folder?.standardizedFileURL
                == sourceFolder?.standardizedFileURL
    }

    private func finishXMPPublicationLifecycle() {
        xmpPublicationGeneration &+= 1
        xmpPublicationCancelFlag = nil
        xmpPublicationTask = nil
        xmpPublicationSessionToken = nil
        xmpPublicationState = .idle
    }

    /// The folder the export started from. Completion refuses to apply moved
    /// IDs to a different session even though the active-operation guards
    /// already prevent folder replacement.
    private var activeExportFolder: URL?

    /// Raises the shared file-operation state before Copy or Move touches the
    /// destination. Copy now receives the same Quit/update/folder-switch
    /// protection as operations that move originals.
    func exportWillStart(mode: ExportMode) -> Bool {
        guard !isNewFileOperationBlocked else { return false }
        guard mode != .metadataXMP else { return false }
        videoPlayback.stop()
        operationRecoveryCause = nil
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
        requiresRecovery: Bool,
        interruptionMessage: String? = nil
    ) {
        guard mode != .metadataXMP else { return }
        let expectedOperation: FileOperationKind = mode == .copy ? .exportCopy : .exportMove
        guard activeFileOperation == expectedOperation else { return }
        let expectedFolder = activeExportFolder
        activeExportFolder = nil
        activeFileOperation = nil
        if requiresRecovery {
            operationRecoveryCause = interruptionMessage
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
        emptySessionReason = items.isEmpty ? .movedOut : nil
        undoStack.removeAll()
        rebuildDerivedData()
        restoreCurrentItem(
            itemID: previousItemID,
            fallbackIndex: previousIndex - removedBefore
        )
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        markSessionChanged()
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

    private func markSessionChanged() {
        if sessionChangeGeneration < UInt64.max {
            sessionChangeGeneration += 1
        }
        // A sidecar-repair warning may truthfully describe the previous
        // durable generation, but it becomes misleading the instant the
        // photographer makes a new change. The scheduled save will publish a
        // fresh warning only if that newer snapshot actually fails.
        if retrySaveIsOptionalSidecarRepair {
            persistenceWarning = nil
        }
    }

    private func scheduleSave() {
        markSessionChanged()
        saveDebounce?.cancel()
        saveTrailingGeneration &+= 1
        let trailingGeneration = saveTrailingGeneration
        let trailingWork = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.saveTrailingGeneration == trailingGeneration,
                      self.saveDebounce != nil else { return }
                self.performScheduledSave()
            }
        }
        saveDebounce = trailingWork
        DispatchQueue.main.asyncAfter(
            deadline: .now() + saveTrailingDelay,
            execute: trailingWork
        )

        // A trailing debounce alone can postpone persistence forever while a
        // photographer rates continuously. Arm one fixed deadline for this
        // dirty cycle; later ratings replace only the trailing save.
        if saveDeadline == nil {
            saveCycleGeneration &+= 1
            let cycleGeneration = saveCycleGeneration
            let deadlineWork = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self,
                          self.saveCycleGeneration == cycleGeneration,
                          self.saveDeadline != nil else { return }
                    self.performScheduledSave()
                }
            }
            saveDeadline = deadlineWork
            DispatchQueue.main.asyncAfter(
                deadline: .now() + saveMaximumDelay,
                execute: deadlineWork
            )
        }
    }

    private func cancelScheduledSave() {
        saveDebounce?.cancel()
        saveDeadline?.cancel()
        saveDebounce = nil
        saveDeadline = nil
        saveTrailingGeneration &+= 1
        saveCycleGeneration &+= 1
    }

    private func performScheduledSave() {
        cancelScheduledSave()
        guard activePersistenceSaveCount == 0 else {
            // Keep only the fact that a newer snapshot is needed. When slow or
            // removable storage finishes the current write, capture one fresh
            // latest snapshot instead of queueing an unbounded series of
            // intermediate 100,000-item payloads.
            saveRequestedWhilePersistenceBusy = true
            return
        }
        saveSession()
    }

    func saveSession() {
        cancelScheduledSave()
        guard let request = makeSaveRequest() else { return }
        saveRequestedWhilePersistenceBusy = false
        enqueuePersistenceSave(request)
    }

    /// Wait for any active checkpoint, then save only when the live session is
    /// newer than its last durable sidecar/backup snapshot. The app delegate
    /// uses this with AppKit's asynchronous termination handshake, so clean
    /// sessions start no redundant write and a last-second rating still
    /// reaches disk. An already-active checkpoint is always awaited.
    func saveSessionForTermination() async -> SessionPersistence.SaveResult? {
        // Quitting while the legacy decision is visible is equivalent to
        // Close Folder: preserve the old snapshot and write nothing.
        guard !isLegacySessionMigrationConfirmationPresented else {
            return nil
        }
        return await persistCurrentSessionIfNeededBeforeDiscard()
    }

    /// Shared Close/Open/Rescan/Quit barrier. The caller first raises either
    /// `isSessionTransitioning` or `isPreparingForTermination`, so no mutation
    /// can arrive after the generation checked here.
    private func persistCurrentSessionIfNeededBeforeDiscard() async
        -> SessionPersistence.SaveResult? {
        cancelScheduledSave()

        // A checkpoint already in flight may contain the complete live
        // session. Await it before deciding whether another write is needed;
        // otherwise a transition duplicates slow removable-volume work and can show
        // a false failure after an identical snapshot was already secured.
        var awaitedResult: SessionPersistence.SaveResult?
        if activePersistenceSaveCount > 0,
           let task = pendingPersistenceTask,
           let request = pendingPersistenceRequest {
            // This transition owns the final coalescing decision from here. The
            // completion observer must not enqueue a third write while this
            // method is suspended awaiting the current one.
            saveRequestedWhilePersistenceBusy = false
            let result = await task.value
            applyPersistenceResult(result, request: request)
            awaitedResult = result
        }

        if persistenceRejectedInvalidSnapshot {
            return .rejectedInvalidSnapshot
        }

        if currentSessionIsDurable {
            return awaitedResult?.canDiscardInMemoryState == true
                ? awaitedResult
                : nil
        }

        if let request = makeSaveRequest() {
            let result = await enqueuePersistenceSave(request).value
            applyPersistenceResult(result, request: request)
            return result
        }

        if let awaitedResult {
            if awaitedResult.canDiscardInMemoryState
                || awaitedResult == .rejectedInvalidSnapshot {
                return awaitedResult
            }
        }

        if let request = retrySaveRequest,
           !retrySaveIsOptionalSidecarRepair {
            let retry = refreshedSaveRequest(from: request)
            let result = await enqueuePersistenceSave(retry).value
            applyPersistenceResult(result, request: retry)
            return result
        }
        return nil
    }

    /// AppKit remains interactive while `.terminateLater` awaits persistence.
    /// Hold this barrier before the final snapshot so no rating can arrive
    /// after the snapshot that authorizes Quit.
    func beginTerminationPreparation() {
        isPreparingForTermination = true
    }

    /// Called only when the photographer cancels Quit after a failed save.
    func cancelTerminationPreparation() {
        isPreparingForTermination = false
    }

    /// Retry the newest live snapshot, or the exact snapshot retained after a
    /// failed Close Session. Success clears the warning automatically.
    func retryPersistence() {
        guard canRetryPersistence else { return }
        cancelScheduledSave()
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
        let access: SessionPersistence.AccessContext
        let changeGeneration: UInt64
    }

    @discardableResult
    private func enqueuePersistenceSave(
        _ request: SaveRequest
    ) -> Task<SessionPersistence.SaveResult, Never> {
        // Any explicitly enqueued snapshot is at least as fresh as the
        // coalesced request from the live store. It therefore satisfies that
        // marker; leaving it set could start an unawaited redundant write
        // after Open, Close, or Quit has already crossed its save barrier.
        saveRequestedWhilePersistenceBusy = false
        activePersistenceSaveCount += 1
        let task = Task.detached { [persistence] in
            await persistence.save(
                request.session,
                for: request.folder,
                sequence: request.sequence,
                access: request.access
            )
        }
        pendingPersistenceTask = task
        pendingPersistenceRequest = request
        Task { @MainActor [weak self] in
            let result = await task.value
            self?.persistenceSaveDidComplete(
                result,
                request: request
            )
        }
        return task
    }

    private func persistenceSaveDidComplete(
        _ result: SessionPersistence.SaveResult,
        request: SaveRequest
    ) {
        activePersistenceSaveCount = max(0, activePersistenceSaveCount - 1)
        applyPersistenceResult(result, request: request)
        guard activePersistenceSaveCount == 0,
              saveRequestedWhilePersistenceBusy else { return }
        saveRequestedWhilePersistenceBusy = false
        saveSession()
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
        let appliesToLiveSession =
            persistenceGenerationAccessID == request.access.id
        let appliesToRetainedRetry = persistenceGenerationAccessID == nil
            && sourceFolder == nil
            && retrySaveRequest?.access.id == request.access.id
        guard appliesToLiveSession || appliesToRetainedRetry else { return }
        guard result != .superseded else { return }
        latestReportedSaveSequence = request.sequence
        let liveRequestWasAlreadyDurable = appliesToLiveSession
            && durableSessionChangeGeneration.map {
                $0 >= request.changeGeneration
            } == true
        let requestWasAlreadyDurable = liveRequestWasAlreadyDurable || (
            appliesToRetainedRetry && retrySaveIsOptionalSidecarRepair
        )
        let liveSessionHasNewerChanges = appliesToLiveSession
            && sessionChangeGeneration > request.changeGeneration

        switch result {
        case .savedToSidecar:
            recordDurableGeneration(for: request)
            retrySaveRequest = nil
            retrySaveIsOptionalSidecarRepair = false
            persistenceWarning = nil
            persistenceRejectedInvalidSnapshot = false
        case .savedToBackup(let sidecarFailure):
            recordDurableGeneration(for: request)
            retrySaveRequest = request
            retrySaveIsOptionalSidecarRepair = true
            persistenceRejectedInvalidSnapshot = false
            guard !liveSessionHasNewerChanges else {
                persistenceWarning = nil
                return
            }
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
            case .busy:
                persistenceWarning = "Another Louppe window is saving this folder. Your ratings are safe in Louppe's backup. Retry in a moment."
            case .encoding, .other:
                persistenceWarning = "Your ratings are safe in Louppe's backup, but the folder session file "
                    + "couldn't be updated. Retry when the folder is available."
            }
        case .failed(let failure):
            retrySaveRequest = request
            retrySaveIsOptionalSidecarRepair = requestWasAlreadyDurable
            persistenceRejectedInvalidSnapshot = false
            if requestWasAlreadyDurable && liveSessionHasNewerChanges {
                persistenceWarning = nil
            } else if requestWasAlreadyDurable {
                persistenceWarning = optionalSidecarRepairWarning(
                    sidecarFailure: failure.sidecar
                )
            } else if failure.sidecar == .busy || failure.backup == .busy {
                persistenceWarning = "Another Louppe window is saving this folder. Your latest ratings are not saved yet. Retry in a moment."
            } else if failure.sidecar == .outOfSpace || failure.backup == .outOfSpace {
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
        case .rejectedInvalidSnapshot:
            retrySaveRequest = nil
            retrySaveIsOptionalSidecarRepair = false
            persistenceRejectedInvalidSnapshot = true
            persistenceWarning = "Louppe stopped an internally inconsistent session snapshot before it could "
                + "replace either saved copy. Keep this session open and report the problem."
        case .sourceFolderChanged:
            retrySaveRequest = request
            retrySaveIsOptionalSidecarRepair = requestWasAlreadyDurable
            persistenceRejectedInvalidSnapshot = false
            if requestWasAlreadyDurable {
                persistenceWarning = liveSessionHasNewerChanges
                    ? nil
                    : "No new ratings are waiting to be saved. The folder or card at this path changed, so its session file was left untouched. Reconnect the original folder to repair it."
            } else {
                persistenceWarning = "The opened folder or card changed before Louppe could save. Neither session copy was touched. Reconnect the original folder, then retry saving."
            }
        case .sidecarChanged:
            retrySaveRequest = request
            retrySaveIsOptionalSidecarRepair = requestWasAlreadyDurable
            persistenceRejectedInvalidSnapshot = false
            if requestWasAlreadyDurable {
                persistenceWarning = liveSessionHasNewerChanges
                    ? nil
                    : "No new ratings are waiting to be saved. This folder's session file changed outside Louppe, so it was left untouched. Restore the version you want before repairing it."
            } else {
                persistenceWarning = "This folder's session file changed outside Louppe after it was opened. Louppe left both versions untouched. Restore the version you want to keep, then retry saving."
            }
        case .superseded:
            break
        }
    }

    private func optionalSidecarRepairWarning(
        sidecarFailure: SessionPersistence.FailureReason
    ) -> String {
        switch sidecarFailure {
        case .permissionDenied:
            return "No new ratings are waiting to be saved. The folder session file is still read-only; restore write access to repair it."
        case .outOfSpace:
            return "No new ratings are waiting to be saved. The folder session file couldn't be repaired because the photo volume is full."
        case .volumeUnavailable:
            return "No new ratings are waiting to be saved. Reconnect the photo volume to repair its folder session file."
        case .busy:
            return "No new ratings are waiting to be saved. Another Louppe window is using this folder; retry the sidecar repair in a moment."
        case .encoding, .other:
            return "No new ratings are waiting to be saved. The folder session file still couldn't be repaired."
        }
    }

    private func recordDurableGeneration(for request: SaveRequest) {
        guard persistenceGenerationAccessID == request.access.id else { return }
        durableSessionChangeGeneration = max(
            durableSessionChangeGeneration ?? 0,
            request.changeGeneration
        )
    }

    private var currentSessionIsDurable: Bool {
        guard let access = persistenceAccess,
              persistenceGenerationAccessID == access.id,
              let durableSessionChangeGeneration else { return false }
        return durableSessionChangeGeneration >= sessionChangeGeneration
    }

    private func refreshedSaveRequest(from request: SaveRequest) -> SaveRequest {
        var session = request.session
        session.scannedAt = Date()
        saveSequence &+= 1
        return SaveRequest(
            folder: request.folder,
            session: session,
            sequence: saveSequence,
            access: request.access,
            changeGeneration: request.changeGeneration
        )
    }

    /// Capture value-semantic session data on the main actor, then let the
    /// persistence actor perform the expensive encoding and file I/O.
    private func makeSaveRequest() -> SaveRequest? {
        guard let folder = sourceFolder,
              let access = persistenceAccess,
              !isLegacySessionMigrationConfirmationPresented,
              case .ready = phase else { return nil }
        let currentEntries = items.flatMap { item in
            item.individualFiles.map { file in
                let metadata = file.metadataSnapshot
                return SessionEntry(
                    filename: file.id,
                    pairedFilename: nil,
                    rating: metadata.rating.rawValue,
                    ratedAt: metadata.ratedAt,
                    stars: metadata.starRating,
                    starsChangedAt: metadata.starsChangedAt,
                    colorLabel: metadata.colorLabel,
                    colorChangedAt: metadata.colorChangedAt,
                    fileIdentity: file.scannedIdentity
                )
            }
        }
        let currentFileIDs = Set(currentEntries.map(\.filename))
        let retainedEntries = retainedMissingSessionEntries.filter {
            !currentFileIDs.contains($0.filename)
        }
        let session = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: folder.path,
            scannedAt: Date(),
            entries: currentEntries + retainedEntries,
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        saveSequence &+= 1
        return SaveRequest(
            folder: folder,
            session: session,
            sequence: saveSequence,
            access: access,
            changeGeneration: sessionChangeGeneration
        )
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
        if hasXMPPublicationSessionState {
            guard !isSessionTransitioning,
                  activeFileOperation == nil,
                  !isPreparingForTermination else { return }
            isSessionTransitioning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cancelAndAwaitXMPPublication()
                self.isExportPresented = false
                self.isSessionTransitioning = false
                self.closeSession()
            }
            return
        }
        guard !isFileOperationRunning else { return }
        if isLegacySessionMigrationConfirmationPresented {
            closeLegacySessionWithoutMigrating()
            return
        }
        isSessionTransitioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self
                .persistCurrentSessionIfNeededBeforeDiscard()
            self.isSessionTransitioning = false
            guard result?.canDiscardInMemoryState != false else { return }
            self.finishClosingSession()
        }
    }

    private func finishClosingSession() {
        finishXMPPublicationLifecycle()
        cancelScheduledSave()
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
        retainedMissingSessionEntries = []
        if retrySaveRequest == nil {
            persistenceWarning = nil
            persistenceRejectedInvalidSnapshot = false
        }
        persistenceAccess = nil
        persistenceGenerationAccessID = nil
        durableSessionChangeGeneration = nil
        sessionChangeGeneration = 0
        isLegacySessionMigrationConfirmationPresented = false
        legacySessionMigrationMissingFileCount = 0
        legacySessionMigrationUsesUnownedBackup = false
        items = []
        emptySessionReason = nil
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
