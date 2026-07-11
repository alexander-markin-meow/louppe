import SwiftUI

struct ExportView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var exporter = ExportManager()

    var body: some View {
        VStack(spacing: 16) {
            switch exporter.state {
            case .summary:
                summaryView
            case .copying(let done, let total):
                copyingView(done: done, total: total)
            case .finished(let copied, let failed, let destination):
                finishedView(copied: copied, failed: failed, destination: destination)
            case .failed(let message):
                failedView(message: message)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var summaryView: some View {
        VStack(spacing: 14) {
            Text("Export Keepers")
                .font(.title2.bold())

            Grid(horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    countCell(store.yesCount, label: "Yes", color: .green)
                    countCell(store.noCount, label: "No", color: .red)
                    countCell(store.undecidedCount, label: "Undecided", color: .secondary)
                }
            }

            let fileCount = store.items.filter { $0.rating == .yes }.flatMap(\.allURLs).count
            Text(exportDescription(fileCount: fileCount))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if store.undecidedCount > 0 {
                Text("\(store.undecidedCount) photo\(store.undecidedCount == 1 ? "" : "s") still undecided — they won't be exported.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { store.isExportPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Destination…") {
                    exporter.promptDestinationAndExport(items: store.items)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.yesCount == 0)
            }
        }
    }

    private func exportDescription(fileCount: Int) -> String {
        if store.yesCount == 0 {
            return "Mark some photos Yes (press Y) before exporting."
        }
        var text = "\(store.yesCount) photo\(store.yesCount == 1 ? "" : "s") will be copied"
        if fileCount != store.yesCount {
            text += " (\(fileCount) files, including RAW+JPEG pairs)"
        }
        text += ". Originals are never touched."
        return text
    }

    private func countCell(_ count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 70)
    }

    private func copyingView(done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            Text("Copying photos…")
                .font(.headline)
            ProgressView(value: Double(done), total: Double(total))
            Text("\(done) of \(total) files")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func finishedView(copied: Int, failed: Int, destination: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(failed == 0 ? .green : .orange)
            Text(failed == 0 ? "Export complete" : "Export finished with problems")
                .font(.title3.bold())
            Text("\(copied) file\(copied == 1 ? "" : "s") copied to \(destination.lastPathComponent)"
                 + (failed > 0 ? " — \(failed) failed to copy." : "."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Show in Finder") {
                    exporter.revealInFinder(destination)
                }
                Button("Done") {
                    store.isExportPresented = false
                    exporter.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
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
