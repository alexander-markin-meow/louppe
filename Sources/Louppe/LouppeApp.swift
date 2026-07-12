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
                Button("Undo Rating") {
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
}
