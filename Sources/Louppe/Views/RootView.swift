import SwiftUI
import AppKit

extension Color {
    /// The single background gray used everywhere in the app (filmstrip, photo
    /// pane, info panel, light table) so there's one consistent shade.
    static let appBackground = Color(nsColor: .windowBackgroundColor)

    /// Louppe's brand purple (#9853A6). The one accent color for everything
    /// that isn't a yes/no rating (those stay green/red): selection borders,
    /// the export button, links, toggles, and the app-icon glyph.
    static let louppeAccent = Color(red: 0x98 / 255, green: 0x53 / 255, blue: 0xA6 / 255)
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
        // Tint every standard control (buttons, links, pickers, toggles,
        // progress bars — including sheets and popovers) with the brand purple.
        .tint(Color.louppeAccent)
        .frame(minWidth: 900, minHeight: 600)
        // The same NSWindow survives all three phases. Welcome/Scanning use
        // full-size content; only the active session opts out so photos cannot
        // scroll behind the glass toolbar. This controls layout, not rounding.
        .background(WindowContentLayout(fullSizeContent: usesFullSizeWindowContent))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.saveSessionBeforeTermination()
        }
    }

    private var usesFullSizeWindowContent: Bool {
        switch store.phase {
        case .welcome, .scanning:
            return true
        case .ready:
            return false
        }
    }
}

/// Keeps the persistent app window's content layout in sync with the current
/// SwiftUI phase. Window corner geometry remains entirely system-owned.
private struct WindowContentLayout: NSViewRepresentable {
    let fullSizeContent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = Configurator()
        view.fullSizeContent = fullSizeContent
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? Configurator else { return }
        view.fullSizeContent = fullSizeContent
        view.apply()
    }

    private final class Configurator: NSView {
        var fullSizeContent = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            guard window.styleMask.contains(.fullSizeContentView) != fullSizeContent else { return }
            if fullSizeContent {
                window.styleMask.insert(.fullSizeContentView)
            } else {
                window.styleMask.remove(.fullSizeContentView)
            }
        }
    }
}
