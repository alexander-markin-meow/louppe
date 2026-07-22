import SwiftUI

struct ExportView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var exporter = ExportManager()
    // The sheet's content is recreated per presentation, so every open starts
    // from the safe default: Copy, keepers only.
    @State private var mode: ExportMode = .copy
    @State private var selectedRatings: Set<Rating> = [.yes]

    var body: some View {
        VStack(spacing: 16) {
            switch exporter.state {
            case .summary:
                summaryView
            case .working(let mode, let done, let total):
                workingView(mode: mode, done: done, total: total)
            case .finished(let outcome):
                finishedView(outcome: outcome)
            case .failed(let message):
                failedView(message: message)
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled(isWorking)
    }

    private var isWorking: Bool {
        if case .working = exporter.state { return true }
        return false
    }

    private var summaryView: some View {
        VStack(spacing: 14) {
            Text("Export")
                .font(.title2.bold())

            Picker("Mode", selection: $mode) {
                Text("Copy to…").tag(ExportMode.copy)
                Text("Move to…").tag(ExportMode.move)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                ratingTile(.yes, count: store.yesCount, label: "Yes", color: .green)
                ratingTile(.no, count: store.noCount, label: "No", color: .red)
                ratingTile(.undecided, count: store.undecidedCount, label: "Undecided", color: .secondary)
            }

            Text(exportDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if mode == .move {
                Text("Moved items leave the source folder and this session. This can't be undone in Louppe — the files stay safe at the destination.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if store.undecidedCount > 0 && !selectedRatings.contains(.undecided) {
                Text("\(store.undecidedCount) item\(store.undecidedCount == 1 ? "" : "s") still undecided — they won't be exported.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { store.isExportPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Destination…") {
                    exporter.promptDestinationAndExport(
                        items: store.items,
                        ratings: selectedRatings,
                        mode: mode,
                        onMoveWillStart: { store.exportMoveWillStart() },
                        onMoveDidFinish: { store.finishExportMove(movedIDs: $0) }
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPhotoCount == 0)
            }
        }
    }

    /// Photos the current tile selection would export — O(1) from the tally.
    private var selectedPhotoCount: Int {
        (selectedRatings.contains(.yes) ? store.yesCount : 0)
            + (selectedRatings.contains(.no) ? store.noCount : 0)
            + (selectedRatings.contains(.undecided) ? store.undecidedCount : 0)
    }

    /// Actual file count, counting RAW+JPEG pairs as two.
    private var selectedFileCount: Int {
        store.items.reduce(0) { $0 + (selectedRatings.contains($1.rating) ? $1.allURLs.count : 0) }
    }

    private var exportDescription: String {
        if selectedRatings.isEmpty {
            return "Select at least one rating tile above to export."
        }
        if selectedPhotoCount == 0 {
            return selectedRatings == [.yes]
                ? "Mark some items Yes (press F) before exporting."
                : "No items have the selected ratings."
        }
        let verb = mode == .copy ? "copied" : "moved"
        var text = "\(selectedPhotoCount) item\(selectedPhotoCount == 1 ? "" : "s") will be \(verb)"
        if selectedFileCount != selectedPhotoCount {
            text += " (\(selectedFileCount) files, including RAW+JPEG pairs)"
        }
        text += mode == .copy ? ". Originals are never touched." : "."
        return text
    }

    private func ratingTile(_ rating: Rating, count: Int, label: String, color: Color) -> some View {
        let isSelected = selectedRatings.contains(rating)
        return Button {
            if isSelected {
                selectedRatings.remove(rating)
            } else {
                selectedRatings.insert(rating)
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(.title.bold())
                    .foregroundStyle(isSelected ? color : color.opacity(0.35))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .frame(minWidth: 70)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Click to leave \(label) items out" : "Click to include \(label) items")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func workingView(mode: ExportMode, done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            Text(mode == .copy ? "Copying media…" : "Moving media…")
                .font(.headline)
            ProgressView(value: Double(done), total: Double(total))
            Text("\(done) of \(total) files")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func finishedView(outcome: ExportManager.Outcome) -> some View {
        VStack(spacing: 14) {
            Image(systemName: outcome.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(outcome.isClean ? .green : .orange)
            Text(outcome.isClean ? "Export complete" : "Export finished with problems")
                .font(.title3.bold())
            Text(finishedMessage(for: outcome))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Show in Finder") {
                    exporter.revealInFinder(outcome.destination)
                }
                Button("Done") {
                    store.isExportPresented = false
                    exporter.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finishedMessage(for outcome: ExportManager.Outcome) -> String {
        let verb = outcome.mode == .copy ? "copied" : "moved"
        var text = "\(outcome.files) file\(outcome.files == 1 ? "" : "s") \(verb) to \(outcome.destination.lastPathComponent)"
        switch outcome.mode {
        case .copy:
            text += outcome.failedFiles > 0 ? " — \(outcome.failedFiles) failed to copy." : "."
        case .move:
            if outcome.failedPhotos > 0 {
                text += " — \(outcome.failedPhotos) item\(outcome.failedPhotos == 1 ? "" : "s") couldn't be moved and stayed in the session."
            } else {
                text += "."
            }
            if outcome.inconsistentPhotos > 0 {
                text += " For \(outcome.inconsistentPhotos), rollback also failed; check both the source folder and the destination."
            }
        }
        return text
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
            Button("OK") {
                exporter.reset()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
