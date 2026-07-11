import Foundation
import AppKit

@MainActor
final class ExportManager: ObservableObject {
    enum State: Equatable {
        case summary
        case copying(done: Int, total: Int)
        case finished(copied: Int, failed: Int, destination: URL)
        case failed(String)
    }

    @Published var state: State = .summary

    func reset() {
        state = .summary
    }

    func promptDestinationAndExport(items: [PhotoItem]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to copy the photos you marked Yes."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        export(items: items, to: destination)
    }

    private func export(items: [PhotoItem], to destination: URL) {
        // Every file to copy: primary file plus its RAW/JPEG partner.
        let sources: [URL] = items.filter { $0.rating == .yes }.flatMap { $0.allURLs }
        guard !sources.isEmpty else {
            state = .failed("There are no photos marked Yes to export.")
            return
        }
        state = .copying(done: 0, total: sources.count)

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var copied = 0
            var failed = 0
            for (i, source) in sources.enumerated() {
                let target = Self.collisionFreeURL(for: source.lastPathComponent, in: destination)
                do {
                    try fm.copyItem(at: source, to: target)
                    copied += 1
                } catch {
                    failed += 1
                }
                let done = i + 1
                await MainActor.run { [copied, failed] in
                    _ = copied; _ = failed
                    self.state = .copying(done: done, total: sources.count)
                }
            }
            await MainActor.run { [copied, failed] in
                self.state = .finished(copied: copied, failed: failed, destination: destination)
            }
        }
    }

    /// `DSC_0001.NEF` → `DSC_0001 (1).NEF` when the name is already taken.
    nonisolated static func collisionFreeURL(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent(filename)
        if !fm.fileExists(atPath: direct.path) { return direct }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
