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
        /// Copy only: files that couldn't be copied.
        let failedFiles: Int
        /// Move only: photos rolled back and left in the source folder.
        let failedPhotos: Int
        /// Move only: photos whose rollback also failed (a pair may be split).
        let inconsistentPhotos: Int
        let destination: URL

        var isClean: Bool { failedFiles == 0 && failedPhotos == 0 && inconsistentPhotos == 0 }
    }

    enum State: Equatable {
        case summary
        case working(mode: ExportMode, done: Int, total: Int)
        case finished(Outcome)
        case failed(String)
    }

    @Published var state: State = .summary

    func reset() {
        state = .summary
    }

    func promptDestinationAndExport(
        items: [PhotoItem],
        ratings: Set<Rating>,
        mode: ExportMode,
        onMoveWillStart: @escaping @MainActor () -> Void,
        onMoveDidFinish: @escaping @MainActor (_ movedIDs: [String]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = mode == .copy
            ? "Choose where to copy the selected photos."
            : "Choose where to move the selected photos."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        export(
            items: items,
            ratings: ratings,
            mode: mode,
            to: destination,
            onMoveWillStart: onMoveWillStart,
            onMoveDidFinish: onMoveDidFinish
        )
    }

    private func export(
        items: [PhotoItem],
        ratings: Set<Rating>,
        mode: ExportMode,
        to destination: URL,
        onMoveWillStart: @MainActor () -> Void,
        onMoveDidFinish: @escaping @MainActor (_ movedIDs: [String]) -> Void
    ) {
        let selected = items.filter { ratings.contains($0.rating) }
        let totalFiles = selected.reduce(0) { $0 + $1.allURLs.count }
        guard totalFiles > 0 else {
            state = .failed("There are no photos with the selected ratings to export.")
            return
        }
        state = .working(mode: mode, done: 0, total: totalFiles)
        // Raise the store's in-flight flag before any file leaves the folder.
        if mode == .move { onMoveWillStart() }

        let progress: ExportWorker.Progress = { [weak self] done, total in
            Task { @MainActor [weak self] in
                // A late throttled tick must never overwrite .finished.
                guard let self, case .working = self.state else { return }
                self.state = .working(mode: mode, done: done, total: total)
            }
        }
        Task.detached(priority: .userInitiated) {
            switch mode {
            case .copy:
                let result = ExportWorker.copy(selected, to: destination, progress: progress)
                await MainActor.run {
                    self.state = .finished(Outcome(
                        mode: .copy,
                        files: result.copiedFiles,
                        failedFiles: result.failedFiles,
                        failedPhotos: 0,
                        inconsistentPhotos: 0,
                        destination: destination
                    ))
                }
            case .move:
                let result = ExportWorker.move(selected, to: destination, progress: progress)
                await MainActor.run {
                    // Always deliver, even an empty list — the store clears
                    // its in-flight flag here.
                    onMoveDidFinish(result.movedItemIDs)
                    self.state = .finished(Outcome(
                        mode: .move,
                        files: result.movedFiles,
                        failedFiles: 0,
                        failedPhotos: result.failedPhotos,
                        inconsistentPhotos: result.inconsistentPhotos,
                        destination: destination
                    ))
                }
            }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
