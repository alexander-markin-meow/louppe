import SwiftUI
import AppKit

extension Color {
    /// The single background gray used everywhere in the app (filmstrip, photo
    /// pane, info panel, light table) so there's one consistent shade.
    static let appBackground = Color(nsColor: .windowBackgroundColor)
}

/// Top-level switch between the three app phases:
/// welcome screen → scanning progress → the culling session.
struct RootView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Group {
            switch store.phase {
            case .welcome:
                WelcomeView(store: store)
            case .scanning(let found):
                ScanningView(found: found)
            case .ready:
                SessionView(store: store)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.saveSession()
        }
    }
}
