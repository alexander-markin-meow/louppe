import SwiftUI
import AppKit

/// Configures the enclosing SwiftUI ScrollView to use AppKit's permanently
/// visible, non-overlay vertical scroller. The legacy style reserves a real
/// gutter beside the content instead of drawing the thumb over photos.
struct PersistentVerticalScroller: NSViewRepresentable {
    static let gutterWidth = NSScroller.scrollerWidth(
        for: .regular,
        scrollerStyle: .legacy
    )

    func makeNSView(context: Context) -> NSView {
        Configurator()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Configurator)?.scheduleConfiguration()
    }

    /// Internal for the focused AppKit regression check.
    static func configure(_ scrollView: NSScrollView) {
        scrollView.scrollerStyle = .legacy
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.controlSize = .regular
        scrollView.autohidesScrollers = false
        scrollView.tile()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private final class Configurator: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            // SwiftUI installs its NSScrollView around this representable later
            // in the update pass, so resolve the enclosing view next turn.
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                PersistentVerticalScroller.configure(scrollView)
            }
        }
    }
}
