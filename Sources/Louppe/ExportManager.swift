import Foundation
import AppKit

/// Runs the Export dialog's file operation: prompts for a destination,
/// receives one prepared metadata-selection snapshot and hands the file loop
/// to ExportWorker off the main actor. Copy never touches originals; Move
/// (owner-sanctioned 2026-07-21) transfers files and reports which photos
/// fully left so SessionStore can drop them from the session.
@MainActor
final class ExportManager: ObservableObject {
    struct Outcome: Equatable {
        let mode: ExportMode
        /// Files that reached the destination.
        let files: Int
        /// Photos whose pair-level copy or move was rolled back.
        let failedPhotos: Int
        /// Photos whose rollback also failed (destination may retain a
        /// partial copy, or a moved pair may be split).
        let inconsistentPhotos: Int
        /// Copy only: the photographer stopped the operation. Completed photos
        /// remain copied; the in-progress photo was rolled back.
        let cancelled: Bool
        /// The operation could not establish or advance its durable
        /// file-safety boundary.
        let journalFailure: Bool
        /// Louppe has started reconciling an interrupted operation. Copy keeps
        /// verified completed files; Move restores its conservative source state.
        let recoveryRequired: Bool
        /// Concrete worker failure retained for the export result and the
        /// recovery alert. Nil only when no useful cause was available.
        let failureMessage: String?
        let destination: URL
        let xmpSummary: ExportWorker.XMPResultSummary?

        var isClean: Bool {
            !cancelled && failedPhotos == 0 && inconsistentPhotos == 0
                && !journalFailure && !recoveryRequired
                && xmpSummary?.hasProblems != true
        }
    }

    struct XMPConfirmation: Equatable {
        let mode: ExportMode
        let destination: URL
        let plan: XMPExportPreparedPlan
    }

    enum State: Equatable {
        case summary
        case preparingXMP(ExportMode)
        case awaitingXMPConfirmation(XMPConfirmation)
        case working(mode: ExportMode, done: Int, total: Int)
        case finished(Outcome)
        case failed(String)
    }

    @Published var state: State = .summary
    @Published private(set) var isCancellingCopy = false
    private var copyCancelFlag: ExportWorker.CancelFlag?
    private var xmpPreparationTask: Task<XMPPreparationResult, Never>?
    private var xmpPreparationID = UUID()
    private var pendingExport: PendingExport?

    func reset() {
        xmpPreparationTask?.cancel()
        xmpPreparationTask = nil
        xmpPreparationID = UUID()
        pendingExport = nil
        state = .summary
        isCancellingCopy = false
        copyCancelFlag = nil
    }

    func promptDestinationAndExport(
        sourceFolder: URL?,
        selected: [PhotoItem],
        familyContextItems: [PhotoItem],
        sessionGeneration: UInt64,
        mode: ExportMode,
        includeXMP: Bool,
        xmpProfile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool,
        onOperationWillStart: @escaping @MainActor (_ mode: ExportMode) -> Bool,
        onOperationDidFinish: @escaping @MainActor (
            _ mode: ExportMode,
            _ movedIDs: [String],
            _ requiresRecovery: Bool,
            _ interruptionMessage: String?
        ) -> Void
    ) {
        guard mode != .metadataXMP else {
            state = .failed("Metadata (XMP) writes beside the originals and does not use a destination.")
            return
        }
        guard !selected.isEmpty else {
            state = .failed("There are no items matching the selected metadata to export.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = mode == .copy
            ? "Choose where to copy the selected media."
            : "Choose where to move the selected media."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let validatedDestination: URL
        do {
            validatedDestination = try ExportDestinationValidator.validate(
                sourceFolder: sourceFolder,
                destination: destination,
                items: selected,
                mode: mode
            )
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        if includeXMP {
            prepareXMPExport(
                selected: selected,
                familyContextItems: familyContextItems,
                sessionGeneration: sessionGeneration,
                mode: mode,
                xmpProfile: xmpProfile,
                visibleDecisionKeywords: visibleDecisionKeywords,
                allowExternalLabelReplacement:
                    allowExternalLabelReplacement,
                sourceFolder: sourceFolder,
                to: validatedDestination,
                onOperationWillStart: onOperationWillStart,
                onOperationDidFinish: onOperationDidFinish
            )
        } else {
            export(
                selected: selected,
                mode: mode,
                xmpPlan: nil,
                to: validatedDestination,
                onOperationWillStart: onOperationWillStart,
                onOperationDidFinish: onOperationDidFinish
            )
        }
    }

    private func prepareXMPExport(
        selected: [PhotoItem],
        familyContextItems: [PhotoItem],
        sessionGeneration: UInt64,
        mode: ExportMode,
        xmpProfile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool,
        sourceFolder: URL?,
        to destination: URL,
        onOperationWillStart: @escaping @MainActor (ExportMode) -> Bool,
        onOperationDidFinish: @escaping @MainActor (
            ExportMode,
            [String],
            Bool,
            String?
        ) -> Void
    ) {
        let input: XMPExportPreparationInput
        do {
            input = try XMPExportPreparationInput(
                selected: selected,
                familyContextItems: familyContextItems,
                sessionGeneration: sessionGeneration,
                profile: xmpProfile,
                visibleDecisionKeywords: visibleDecisionKeywords,
                allowExternalLabelReplacement:
                    allowExternalLabelReplacement
            )
        } catch {
            state = .failed(
                "XMP could not be prepared safely. \(error.localizedDescription)"
            )
            return
        }
        let preparationID = UUID()
        xmpPreparationID = preparationID
        state = .preparingXMP(mode)
        let worker = Task.detached(priority: .userInitiated) {
            () -> XMPPreparationResult in
            do {
                return .prepared(
                    try await XMPExportPlanner.prepare(input)
                )
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        xmpPreparationTask = worker
        Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self, self.xmpPreparationID == preparationID else {
                return
            }
            self.xmpPreparationTask = nil
            switch result {
            case .prepared(let plan):
                self.pendingExport = PendingExport(
                    selected: selected,
                    sourceFolder: sourceFolder,
                    mode: mode,
                    destination: destination,
                    plan: plan,
                    xmpProfile: xmpProfile,
                    visibleDecisionKeywords: visibleDecisionKeywords,
                    allowExternalLabelReplacement:
                        allowExternalLabelReplacement,
                    onOperationWillStart: onOperationWillStart,
                    onOperationDidFinish: onOperationDidFinish
                )
                self.state = .awaitingXMPConfirmation(XMPConfirmation(
                    mode: mode,
                    destination: destination,
                    plan: plan
                ))
            case .cancelled:
                self.pendingExport = nil
                self.state = .summary
            case .failed(let message):
                self.pendingExport = nil
                self.state = .failed(
                    "XMP could not be prepared safely. \(message)"
                )
            }
        }
    }

    func confirmXMPExport() {
        guard let pendingExport,
              case .awaitingXMPConfirmation = state else { return }
        self.pendingExport = nil
        export(
            selected: pendingExport.selected,
            mode: pendingExport.mode,
            xmpPlan: pendingExport.plan,
            to: pendingExport.destination,
            onOperationWillStart: pendingExport.onOperationWillStart,
            onOperationDidFinish: pendingExport.onOperationDidFinish
        )
    }

    /// Discards the old immutable XMP/media selection after a conflict
    /// resolution, revalidates the retained destination, and performs the
    /// complete planner pass again before confirmation can be offered.
    func reprepareXMPExportAfterResolution(
        selected: [PhotoItem],
        familyContextItems: [PhotoItem],
        sessionGeneration: UInt64
    ) {
        guard let pendingExport,
              case .awaitingXMPConfirmation = state else { return }
        guard !selected.isEmpty else {
            self.pendingExport = nil
            state = .failed(
                "After resolving the RAW + JPEG metadata, no items match the selected Export filters."
            )
            return
        }
        let destination: URL
        do {
            destination = try ExportDestinationValidator.validate(
                sourceFolder: pendingExport.sourceFolder,
                destination: pendingExport.destination,
                items: selected,
                mode: pendingExport.mode
            )
        } catch {
            self.pendingExport = nil
            state = .failed(error.localizedDescription)
            return
        }
        self.pendingExport = nil
        prepareXMPExport(
            selected: selected,
            familyContextItems: familyContextItems,
            sessionGeneration: sessionGeneration,
            mode: pendingExport.mode,
            xmpProfile: pendingExport.xmpProfile,
            visibleDecisionKeywords: pendingExport.visibleDecisionKeywords,
            allowExternalLabelReplacement:
                pendingExport.allowExternalLabelReplacement,
            sourceFolder: pendingExport.sourceFolder,
            to: destination,
            onOperationWillStart: pendingExport.onOperationWillStart,
            onOperationDidFinish: pendingExport.onOperationDidFinish
        )
    }

    func cancelXMPPreparation() {
        guard case .preparingXMP = state else { return }
        xmpPreparationTask?.cancel()
        xmpPreparationTask = nil
        xmpPreparationID = UUID()
        pendingExport = nil
        state = .summary
    }

    func backFromXMPConfirmation() {
        guard case .awaitingXMPConfirmation = state else { return }
        pendingExport = nil
        state = .summary
    }

    private func export(
        selected: [PhotoItem],
        mode: ExportMode,
        xmpPlan: XMPExportPreparedPlan?,
        to destination: URL,
        onOperationWillStart: @MainActor (_ mode: ExportMode) -> Bool,
        onOperationDidFinish: @escaping @MainActor (
            _ mode: ExportMode,
            _ movedIDs: [String],
            _ requiresRecovery: Bool,
            _ interruptionMessage: String?
        ) -> Void
    ) {
        let totalFiles = selected.reduce(0) { $0 + $1.allURLs.count }
        guard totalFiles > 0, onOperationWillStart(mode) else {
            state = .failed("Another file operation is already running. Wait for it to finish, then try again.")
            return
        }

        isCancellingCopy = false
        let cancelFlag = mode == .copy ? ExportWorker.CancelFlag() : nil
        copyCancelFlag = cancelFlag
        state = .working(mode: mode, done: 0, total: totalFiles)

        let progress: ExportWorker.Progress = { [weak self] done, total in
            Task { @MainActor [weak self] in
                // A late throttled tick must never overwrite .finished.
                guard let self, case .working = self.state else { return }
                self.state = .working(mode: mode, done: done, total: total)
            }
        }

        let worker = Task.detached(priority: .userInitiated) {
            () -> WorkerResult in
            if mode == .copy {
                return .copy(ExportWorker.copy(
                    selected,
                    to: destination,
                    xmpPlan: xmpPlan,
                    isCancelled: { cancelFlag?.isSet ?? false },
                    progress: progress
                ))
            }
            return .move(ExportWorker.move(
                selected,
                to: destination,
                xmpPlan: xmpPlan,
                progress: progress
            ))
        }

        Task { @MainActor in
            let result = await worker.value
            copyCancelFlag = nil
            isCancellingCopy = false
            switch result {
            case .copy(let copy):
                onOperationDidFinish(
                    .copy,
                    [],
                    copy.requiresRecovery,
                    copy.failureMessage
                )
                state = .finished(Outcome(
                    mode: .copy,
                    files: copy.xmpSummary?.mediaFiles
                        ?? copy.copiedFiles,
                    failedPhotos: copy.failedPhotos,
                    inconsistentPhotos: copy.inconsistentPhotos,
                    cancelled: copy.cancelled,
                    journalFailure: copy.journalFailure,
                    recoveryRequired: copy.requiresRecovery,
                    failureMessage: copy.failureMessage,
                    destination: destination,
                    xmpSummary: copy.xmpSummary
                ))
            case .move(let move):
                // Always deliver, even an empty list — the store clears its
                // in-flight state here.
                onOperationDidFinish(
                    .move,
                    move.requiresRecovery ? [] : move.movedItemIDs,
                    move.requiresRecovery,
                    move.failureMessage
                )
                state = .finished(Outcome(
                    mode: .move,
                    files: move.xmpSummary?.mediaFiles
                        ?? move.movedFiles,
                    failedPhotos: move.failedPhotos,
                    inconsistentPhotos: move.inconsistentPhotos,
                    cancelled: false,
                    journalFailure: move.journalFailure,
                    recoveryRequired: move.requiresRecovery,
                    failureMessage: move.failureMessage,
                    destination: destination,
                    xmpSummary: move.xmpSummary
                ))
            }
        }
    }

    func cancelCopy() {
        guard case .working(mode: .copy, done: _, total: _) = state else { return }
        isCancellingCopy = true
        copyCancelFlag?.set()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private enum WorkerResult: Sendable {
        case copy(ExportWorker.CopyResult)
        case move(ExportWorker.MoveResult)
    }

    private enum XMPPreparationResult: Sendable {
        case prepared(XMPExportPreparedPlan)
        case cancelled
        case failed(String)
    }

    private struct PendingExport {
        let selected: [PhotoItem]
        let sourceFolder: URL?
        let mode: ExportMode
        let destination: URL
        let plan: XMPExportPreparedPlan
        let xmpProfile: XMPApplicationProfile
        let visibleDecisionKeywords: Bool
        let allowExternalLabelReplacement: Bool
        let onOperationWillStart: @MainActor (ExportMode) -> Bool
        let onOperationDidFinish: @MainActor (
            ExportMode,
            [String],
            Bool,
            String?
        ) -> Void
    }
}

private extension ExportWorker.XMPResultSummary {
    var hasProblems: Bool {
        unsupported > 0 || skipped > 0 || conflicts > 0 || failed > 0
    }
}
