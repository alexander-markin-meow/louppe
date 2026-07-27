import Foundation
import AppKit

/// Runs the Export dialog's file operation: prompts for a destination,
/// filters the session to the chosen ratings, and hands the file loop to
/// ExportWorker off the main actor. Copy never touches originals; Move
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
        /// The operation's durable checkpoint could not be written.
        let journalFailure: Bool
        /// Louppe has started restoring the conservative pre-export state.
        let recoveryRequired: Bool
        let destination: URL

        var isClean: Bool {
            !cancelled && failedPhotos == 0 && inconsistentPhotos == 0
                && !journalFailure && !recoveryRequired
        }
    }

    enum State: Equatable {
        case summary
        case working(mode: ExportMode, done: Int, total: Int)
        case finished(Outcome)
        case failed(String)
    }

    @Published var state: State = .summary
    @Published private(set) var isCancellingCopy = false
    private var copyCancelFlag: ExportWorker.CancelFlag?

    func reset() {
        state = .summary
        isCancellingCopy = false
        copyCancelFlag = nil
    }

    func promptDestinationAndExport(
        sourceFolder: URL?,
        items: [PhotoItem],
        ratings: Set<Rating>,
        mode: ExportMode,
        onOperationWillStart: @escaping @MainActor (_ mode: ExportMode) -> Bool,
        onOperationDidFinish: @escaping @MainActor (
            _ mode: ExportMode,
            _ movedIDs: [String],
            _ requiresRecovery: Bool
        ) -> Void
    ) {
        let selected = items.filter { ratings.contains($0.rating) }
        guard !selected.isEmpty else {
            state = .failed("There are no items with the selected ratings to export.")
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

        do {
            try ExportDestinationValidator.validate(
                sourceFolder: sourceFolder,
                destination: destination,
                items: selected,
                mode: mode
            )
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        export(
            selected: selected,
            mode: mode,
            to: destination,
            onOperationWillStart: onOperationWillStart,
            onOperationDidFinish: onOperationDidFinish
        )
    }

    private func export(
        selected: [PhotoItem],
        mode: ExportMode,
        to destination: URL,
        onOperationWillStart: @MainActor (_ mode: ExportMode) -> Bool,
        onOperationDidFinish: @escaping @MainActor (
            _ mode: ExportMode,
            _ movedIDs: [String],
            _ requiresRecovery: Bool
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

        let worker = Task.detached(priority: .userInitiated) { () -> WorkerResult in
            switch mode {
            case .copy:
                return .copy(ExportWorker.copy(
                    selected,
                    to: destination,
                    isCancelled: { cancelFlag?.isSet ?? false },
                    progress: progress
                ))
            case .move:
                return .move(ExportWorker.move(
                    selected,
                    to: destination,
                    progress: progress
                ))
            }
        }

        Task { @MainActor in
            let result = await worker.value
            copyCancelFlag = nil
            isCancellingCopy = false
            switch result {
            case .copy(let copy):
                onOperationDidFinish(.copy, [], copy.requiresRecovery)
                state = .finished(Outcome(
                    mode: .copy,
                    files: copy.copiedFiles,
                    failedPhotos: copy.failedPhotos,
                    inconsistentPhotos: copy.inconsistentPhotos,
                    cancelled: copy.cancelled,
                    journalFailure: copy.journalFailure,
                    recoveryRequired: copy.requiresRecovery,
                    destination: destination
                ))
            case .move(let move):
                // Always deliver, even an empty list — the store clears its
                // in-flight state here.
                onOperationDidFinish(
                    .move,
                    move.requiresRecovery ? [] : move.movedItemIDs,
                    move.requiresRecovery
                )
                state = .finished(Outcome(
                    mode: .move,
                    files: move.movedFiles,
                    failedPhotos: move.failedPhotos,
                    inconsistentPhotos: move.inconsistentPhotos,
                    cancelled: false,
                    journalFailure: move.journalFailure,
                    recoveryRequired: move.requiresRecovery,
                    destination: destination
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
}
