import SwiftUI
import AppKit

/// Configures the enclosing SwiftUI ScrollView with a permanently visible
/// vertical scroller. It keeps AppKit's proportional scrolling behavior and a
/// real layout gutter, while drawing the wide rounded style used by overlay
/// scrollers instead of the narrower legacy thumb.
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
        // SwiftUI's standard scroller remains eligible for the system's fade
        // treatment. This subclass opts out, then paints the preferred rounded
        // overlay-style track and thumb itself so it never fades away.
        if !(scrollView.verticalScroller is AlwaysVisibleScroller) {
            scrollView.verticalScroller = AlwaysVisibleScroller()
        }
        scrollView.scrollerStyle = .legacy
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.controlSize = .regular
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
        scrollView.autohidesScrollers = false
        scrollView.tile()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    static func hasAlwaysVisibleScroller(_ scrollView: NSScrollView) -> Bool {
        scrollView.verticalScroller is AlwaysVisibleScroller
    }

    private final class AlwaysVisibleScroller: NSScroller {
        override class var isCompatibleWithOverlayScrollers: Bool { false }

        private let visualWidth: CGFloat = 11
        private let minimumKnobHeight: CGFloat = 20

        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
            let rect = centeredRect(in: slotRect, width: visualWidth)
            trackColor.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: visualWidth / 2,
                yRadius: visualWidth / 2
            ).fill()
        }

        override func drawKnob() {
            let appKitRect = rect(for: .knob)
            guard !appKitRect.isEmpty else { return }

            let height = min(max(appKitRect.height, minimumKnobHeight), bounds.height)
            let y = min(
                max(appKitRect.midY - height / 2, bounds.minY),
                bounds.maxY - height
            )
            let rect = NSRect(
                x: bounds.midX - visualWidth / 2,
                y: y,
                width: visualWidth,
                height: height
            )
            knobColor.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: visualWidth / 2,
                yRadius: visualWidth / 2
            ).fill()
        }

        private func centeredRect(in rect: NSRect, width: CGFloat) -> NSRect {
            NSRect(
                x: bounds.midX - width / 2,
                y: rect.minY,
                width: width,
                height: rect.height
            )
        }

        private var usesDarkAppearance: Bool {
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        private var trackColor: NSColor {
            usesDarkAppearance
                ? NSColor.white.withAlphaComponent(0.055)
                : NSColor.black.withAlphaComponent(0.055)
        }

        private var knobColor: NSColor {
            usesDarkAppearance
                ? NSColor.white.withAlphaComponent(0.58)
                : NSColor.black.withAlphaComponent(0.42)
        }
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
