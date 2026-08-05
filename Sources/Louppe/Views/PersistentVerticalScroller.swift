import SwiftUI
import AppKit

/// Configures the enclosing SwiftUI ScrollView with AppKit's permanently
/// visible native vertical scroller. The non-overlay style reserves a real
/// gutter and lets AppKit keep the indicator synchronized during live scroll.
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
        // updateNSView re-runs this on every SwiftUI update pass (every store
        // publish). Once the scroll view holds a fully configured scroller,
        // skip the replace/tile work; any drifted property re-takes the full
        // path, so the invariant remains self-healing.
        if scrollView.scrollerStyle == .legacy,
           scrollView.hasVerticalScroller,
           !scrollView.autohidesScrollers,
           scrollView.verticalScroller?.controlSize == .regular,
           scrollView.verticalScroller?.isHidden == false,
           scrollView.verticalScroller?.alphaValue == 1 {
            return
        }
        // Keep the NSScroller object installed by AppKit. Replacing it with a
        // hand-drawn subclass made the indicator miss live-scroll frames while
        // the lazy Grid was realizing tiles.
        scrollView.scrollerStyle = .legacy
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.controlSize = .regular
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
        scrollView.autohidesScrollers = false
        scrollView.tile()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private final class Configurator: NSView {
        private var configurationScheduled = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            // Once mounted, update synchronously. Queueing one block for every
            // lazy-Grid update can make those callbacks compete with live
            // scrolling even though configure itself immediately returns.
            if let scrollView = enclosingScrollView {
                PersistentVerticalScroller.configure(scrollView)
                return
            }

            // SwiftUI can install its NSScrollView around this representable
            // later in the first update pass. Coalesce those unresolved calls
            // into one next-turn lookup.
            guard !configurationScheduled else { return }
            configurationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                guard let scrollView = self.enclosingScrollView else { return }
                PersistentVerticalScroller.configure(scrollView)
            }
        }
    }
}
