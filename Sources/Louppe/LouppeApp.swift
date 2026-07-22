import SwiftUI
import AppKit

@main
struct LouppeApp: App {
    @NSApplicationDelegateAdaptor(LouppeApplicationDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()

    var body: some Scene {
        Window("Louppe", id: "main") {
            RootView(store: store)
                .onAppear {
                    appDelegate.store = store
                    NSApp.activate(ignoringOtherApps: true)
                    // Optional launch argument for testing:
                    //   open Louppe.app --args -openFolder /path/to/photos
                    // Flag-style on purpose: a bare path argument makes macOS
                    // treat the launch as a document-open request and suppress
                    // the app's default window entirely.
                    if let path = UserDefaults.standard.string(forKey: "openFolder"),
                       FileManager.default.fileExists(atPath: path) {
                        store.openFolder(URL(fileURLWithPath: path))
                    }
                }
        }
        // Keep the system-owned macOS window chrome. This adopts the current
        // platform appearance (including macOS 26 window geometry) instead of
        // freezing a custom or plain style in the app.
        .windowStyle(.automatic)
        .commands {
            // Standard About panel reads its version from the release bundle
            // and adds credits plus a link to the complete release history.
            CommandGroup(replacing: .appInfo) {
                Button("About Louppe") {
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    store.promptForSourceFolder()
                }
                .keyboardShortcut("o")
                .disabled(store.isCleaningUp || store.isMovingExport)

                Button("Rescan Folder") {
                    store.rescan()
                }
                .keyboardShortcut("r")
                .disabled(store.sourceFolder == nil || store.isCleaningUp || store.isMovingExport)

                Button("Close Session") {
                    store.closeSession()
                }
                .disabled(store.sourceFolder == nil || store.isCleaningUp || store.isMovingExport)
            }
            CommandGroup(replacing: .undoRedo) {
                // Undoes ratings and clean-ups alike, so just "Undo".
                Button("Undo") {
                    store.undo()
                }
                .keyboardShortcut("z")
                .disabled(store.isCleaningUp || store.isMovingExport || !store.canUndo)

                Button("Clear All Ratings") {
                    store.requestClearAllRatings()
                }
                .disabled(store.ratedCount == 0 || store.isCleaningUp || store.isMovingExport)
            }
            CommandGroup(after: .saveItem) {
                Button("Export…") {
                    store.isExportPresented = true
                }
                .keyboardShortcut("e")
                .disabled(store.items.isEmpty || store.isCleaningUp || store.isMovingExport)

                Divider()

                // Clean Up asks for confirmation in the session window
                // (SessionView presents the dialog when pendingCleanUp is set).
                Menu("Clean Up") {
                    CleanUpMenuItems(store: store)
                }
                .disabled(store.items.isEmpty || store.isCleaningUp || store.isMovingExport)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    store.zoomGrid(larger: true)
                }
                .keyboardShortcut("+")
                .disabled(store.viewMode != .grid)

                Button("Zoom Out") {
                    store.zoomGrid(larger: false)
                }
                .keyboardShortcut("-")
                .disabled(store.viewMode != .grid)
            }
        }
    }

    /// Credits block for the About panel. Links are clickable.
    private static var aboutCredits: NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center,
        ]
        var link = base
        let credits = NSMutableAttributedString()

        credits.append(NSAttributedString(
            string: "Fast photo and video culling for photographers.\n\n", attributes: base))

        link[.link] = URL(string: "https://github.com/alexander-markin-meow/louppe/releases")!
        credits.append(NSAttributedString(string: "Version History", attributes: link))
        credits.append(NSAttributedString(string: "\n\n", attributes: base))

        credits.append(NSAttributedString(
            string: "Created by Alex Markin\n", attributes: base))

        link[.link] = URL(string: "mailto:a@alex-markin.com")!
        credits.append(NSAttributedString(string: "a@alex-markin.com", attributes: link))
        credits.append(NSAttributedString(string: "\n", attributes: base))

        link[.link] = URL(string: "https://github.com/alexander-markin-meow/louppe")!
        credits.append(NSAttributedString(string: "GitHub", attributes: link))

        return credits
    }
}

/// A Trash/restore or Move-export batch cannot be made transactional by the
/// filesystem. Keep the process alive until its worker has either completed or
/// rolled a partial RAW+JPEG operation back, instead of allowing Quit to
/// strand half a pair.
@MainActor
private final class LouppeApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: SessionStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isMovingExport == true {
            let alert = NSAlert()
            alert.messageText = "Export is still moving files"
            alert.informativeText = "Wait for the move to finish, then quit Louppe."
            alert.alertStyle = .warning
            alert.runModal()
            return .terminateCancel
        }
        guard store?.isCleaningUp == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Clean Up is still running"
        alert.informativeText = "Wait for the Trash or restore progress to finish, then quit Louppe."
        alert.alertStyle = .warning
        alert.runModal()
        return .terminateCancel
    }
}
