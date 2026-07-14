import SwiftUI
import AppKit

@main
struct LouppeApp: App {
    @StateObject private var store = SessionStore()

    var body: some Scene {
        Window("Louppe", id: "main") {
            RootView(store: store)
                .onAppear {
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
        .commands {
            // Standard About panel (icon, name, version, copyright) with a
            // custom credits section: author, contact email, GitHub link.
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

                Button("Rescan Folder") {
                    store.rescan()
                }
                .keyboardShortcut("r")
                .disabled(store.sourceFolder == nil)

                Button("Close Session") {
                    store.closeSession()
                }
                .disabled(store.sourceFolder == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                // Undoes ratings and clean-ups alike, so just "Undo".
                Button("Undo") {
                    store.undo()
                }
                .keyboardShortcut("z")

                Button("Clear All Ratings") {
                    store.clearAllRatings()
                }
                .disabled(store.items.isEmpty)
            }
            CommandGroup(after: .saveItem) {
                Button("Export…") {
                    store.isExportPresented = true
                }
                .keyboardShortcut("e")
                .disabled(store.items.isEmpty)

                Divider()

                // Clean Up asks for confirmation in the session window
                // (SessionView presents the dialog when pendingCleanUp is set).
                Menu("Clean Up") {
                    CleanUpMenuItems(store: store)
                }
                .disabled(store.items.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    store.zoomGrid(larger: true)
                }
                .keyboardShortcut("+")
                .disabled(store.viewMode != .lightTable)

                Button("Zoom Out") {
                    store.zoomGrid(larger: false)
                }
                .keyboardShortcut("-")
                .disabled(store.viewMode != .lightTable)
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
            string: "Fast photo culling for photographers.\n\n", attributes: base))
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
