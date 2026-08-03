import SwiftUI
import AppKit
import Sparkle

@main
struct LouppeApp: App {
    @NSApplicationDelegateAdaptor(LouppeApplicationDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore(
        automaticallyRecoversInterruptedOperations: true
    )
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
                .disabled(
                    store.isFileOperationRunning
                        || store.isSessionCommandPresentationActive
                )
            }
            FocusedLouppeSessionCommands(store: store)
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

/// Session commands are available only while Louppe's photo window is the
/// focused scene. `SessionView` owns their key equivalents because it can prove
/// the live window and responder context; keeping duplicate equivalents out of
/// the menu prevents them from bypassing text selection or AppKit's Undo.
private struct FocusedLouppeSessionCommands: Commands {
    @ObservedObject var store: SessionStore
    @FocusedValue(\.louppeSessionStore) private var sceneStore

    private var focusedStore: SessionStore? {
        guard sceneStore === store else { return nil }
        return sceneStore
    }

    private var actionableStore: SessionStore? {
        guard let focusedStore,
              !focusedStore.isSessionCommandPresentationActive else {
            return nil
        }
        return focusedStore
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Rescan Folder") {
                actionableStore?.rescan()
            }
            .disabled(
                actionableStore?.sourceFolder == nil
                    || actionableStore?.isFileOperationRunning != false
            )

            Button("Close Session") {
                actionableStore?.closeSession()
            }
            .disabled(
                actionableStore?.sourceFolder == nil
                    || actionableStore?.isFileOperationRunning != false
            )
        }

        CommandGroup(after: .undoRedo) {
            Button("Undo Louppe Action") {
                actionableStore?.undo()
            }
            .disabled(
                actionableStore?.isFileOperationRunning != false
                    || actionableStore?.canUndo != true
            )

            Button("Clear All Ratings") {
                actionableStore?.requestClearAllRatings()
            }
            .disabled(
                actionableStore?.ratedCount == 0
                    || actionableStore?.isFileOperationRunning != false
            )
        }

        CommandGroup(after: .saveItem) {
            Button("Export…") {
                actionableStore?.presentExport()
            }
            .disabled(
                actionableStore?.canExport != true
            )

            Divider()

            // Clean Up asks for confirmation in the session window
            // (SessionView presents the dialog when pendingCleanUp is set).
            Menu("Clean Up") {
                CleanUpMenuItems(store: store)
            }
            .disabled(
                actionableStore?.canCleanUp != true
            )
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") {
                actionableStore?.zoomGrid(larger: true)
            }
            .disabled(actionableStore?.viewMode != .grid)

            Button("Zoom Out") {
                actionableStore?.zoomGrid(larger: false)
            }
            .disabled(actionableStore?.viewMode != .grid)
        }
    }
}

private struct LouppeSessionStoreFocusedValueKey: FocusedValueKey {
    typealias Value = SessionStore
}

extension FocusedValues {
    var louppeSessionStore: SessionStore? {
        get { self[LouppeSessionStoreFocusedValueKey.self] }
        set { self[LouppeSessionStoreFocusedValueKey.self] = newValue }
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
        // `.terminateLater` leaves AppKit interactive while persistence runs.
        // Freeze rating/navigation commands before taking the final snapshot
        // so a last key press cannot land after the data that authorizes Quit.
        store.beginTerminationPreparation()
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
            if result == .rejectedInvalidSnapshot {
                self.presentInvalidSnapshotFailure(
                    store: store,
                    application: application
                )
                return
            }
            self.presentSaveFailure(store: store, application: application)
        }
    }

    private func presentInvalidSnapshotFailure(
        store: SessionStore,
        application: NSApplication
    ) {
        let alert = NSAlert()
        alert.messageText = "Session data failed a safety check"
        alert.informativeText = "Louppe refused to replace your saved ratings because the new snapshot "
            + "was internally inconsistent. Cancel Quit and keep this session open; you can quit without "
            + "saving only if you accept losing the latest in-memory changes."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel Quit")
        alert.addButton(withTitle: "Quit Without Saving")

        if alert.runModal() == .alertSecondButtonReturn {
            isPreparingToTerminate = false
            application.reply(toApplicationShouldTerminate: true)
        } else {
            isPreparingToTerminate = false
            store.cancelTerminationPreparation()
            application.reply(toApplicationShouldTerminate: false)
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
            store.cancelTerminationPreparation()
            application.reply(toApplicationShouldTerminate: false)
        }
    }
}
