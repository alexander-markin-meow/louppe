import SwiftUI
import AppKit
import Sparkle

@main
struct LouppeApp: App {
    @NSApplicationDelegateAdaptor(LouppeApplicationDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(
                    updater: updaterController.updater,
                    isFileOperationRunning: store.isFileOperationRunning
                )
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    store.promptForSourceFolder()
                }
                .keyboardShortcut("o")
                .disabled(store.isFileOperationRunning)

                Button("Rescan Folder") {
                    store.rescan()
                }
                .keyboardShortcut("r")
                .disabled(store.sourceFolder == nil || store.isFileOperationRunning)

                Button("Close Session") {
                    store.closeSession()
                }
                .disabled(store.sourceFolder == nil || store.isFileOperationRunning)
            }
            CommandGroup(replacing: .undoRedo) {
                // Undoes ratings and clean-ups alike, so just "Undo".
                Button("Undo") {
                    store.undo()
                }
                .keyboardShortcut("z")
                .disabled(store.isFileOperationRunning || !store.canUndo)

                Button("Clear All Ratings") {
                    store.requestClearAllRatings()
                }
                .disabled(store.ratedCount == 0 || store.isFileOperationRunning)
            }
            CommandGroup(after: .saveItem) {
                Button("Export…") {
                    store.isExportPresented = true
                }
                .keyboardShortcut("e")
                .disabled(store.items.isEmpty || store.isFileOperationRunning)

                Divider()

                // Clean Up asks for confirmation in the session window
                // (SessionView presents the dialog when pendingCleanUp is set).
                Menu("Clean Up") {
                    CleanUpMenuItems(store: store)
                }
                .disabled(store.items.isEmpty || store.isFileOperationRunning)
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

        Settings {
            UpdaterSettingsView(updater: updaterController.updater)
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

/// Keep the process alive until file operations are safe and the newest rating
/// snapshot reaches stable storage. AppKit's terminate-later handshake avoids
/// freezing the main thread during the final save.
@MainActor
private final class LouppeApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: SessionStore?
    private var isPreparingToTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isRecoveringInterruptedOperations == true {
            let alert = NSAlert()
            alert.messageText = "File recovery is still running"
            alert.informativeText = "Wait for Louppe to finish making the interrupted operation safe, then quit."
            alert.alertStyle = .warning
            alert.runModal()
            return .terminateCancel
        }
        if let operation = store?.activeFileOperation {
            let alert = NSAlert()
            switch operation {
            case .exportCopy:
                alert.messageText = "Export is still copying files"
                alert.informativeText = "Stop the copy or wait for it to finish, then quit Louppe."
            case .exportMove:
                alert.messageText = "Export is still moving files"
                alert.informativeText = "Wait for the move to finish, then quit Louppe."
            case .cleanUp:
                alert.messageText = "Clean Up is still running"
                alert.informativeText = "Wait for the Trash or restore progress to finish, then quit Louppe."
            }
            alert.alertStyle = .warning
            alert.runModal()
            return .terminateCancel
        }
        guard let store else { return .terminateNow }
        guard !isPreparingToTerminate else { return .terminateLater }
        isPreparingToTerminate = true
        attemptFinalSave(store: store, application: sender)
        return .terminateLater
    }

    private func attemptFinalSave(
        store: SessionStore,
        application: NSApplication
    ) {
        Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                application.reply(toApplicationShouldTerminate: true)
                return
            }
            let result = await store.saveSessionForTermination()
            if result?.canDiscardInMemoryState != false {
                self.isPreparingToTerminate = false
                application.reply(toApplicationShouldTerminate: true)
                return
            }
            self.presentSaveFailure(store: store, application: application)
        }
    }

    private func presentSaveFailure(
        store: SessionStore,
        application: NSApplication
    ) {
        let alert = NSAlert()
        alert.messageText = "Your latest ratings aren't saved"
        alert.informativeText = "Louppe couldn't save them in the photo folder or its backup. "
            + "Retry after reconnecting the volume, freeing space, or fixing permissions."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Retry Saving")
        alert.addButton(withTitle: "Cancel Quit")
        alert.addButton(withTitle: "Quit Without Saving")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            attemptFinalSave(store: store, application: application)
        case .alertThirdButtonReturn:
            isPreparingToTerminate = false
            application.reply(toApplicationShouldTerminate: true)
        default:
            isPreparingToTerminate = false
            application.reply(toApplicationShouldTerminate: false)
        }
    }
}
