import AppKit

@main
struct ScrollbarChecks {
    @MainActor
    static func main() throws {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400)
        )
        // Settle AppKit on the non-overlay style before capturing its native
        // scroller. Louppe may configure visibility and the gutter, but must
        // not replace this optimized control with a hand-drawn subclass.
        scrollView.scrollerStyle = .legacy
        scrollView.hasVerticalScroller = true
        guard let nativeScroller = scrollView.verticalScroller else {
            throw CheckFailure("AppKit must provide a native vertical scroller")
        }
        scrollView.documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 1_000)
        )

        PersistentVerticalScroller.configure(scrollView)

        try expect(
            scrollView.verticalScroller === nativeScroller,
            "configuration must retain AppKit's native scrolling indicator"
        )
        try expect(scrollView.scrollerStyle == .legacy, "scroller must use the non-overlay legacy style")
        try expect(scrollView.hasVerticalScroller, "vertical scroller must be installed")
        try expect(!scrollView.autohidesScrollers, "vertical scroller must never autohide")
        try expect(scrollView.verticalScroller?.isHidden == false, "vertical scroller must remain visible")
        try expect(scrollView.verticalScroller?.isEnabled == true, "vertical scroller must be active for overflowing content")
        try expect(scrollView.verticalScroller?.alphaValue == 1, "vertical scroller must remain fully opaque")

        guard let scroller = scrollView.verticalScroller else {
            throw CheckFailure("vertical scroller must exist")
        }
        let shorterContentKnobHeight = scroller.rect(for: .knob).height
        scrollView.documentView?.frame.size.height = 2_000
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let longerContentKnobHeight = scroller.rect(for: .knob).height
        try expect(
            longerContentKnobHeight < shorterContentKnobHeight,
            "thumb height must shrink proportionally as scrollable content grows"
        )

        let reservedWidth = scrollView.bounds.width - scrollView.contentSize.width
        try expect(
            abs(reservedWidth - PersistentVerticalScroller.gutterWidth) < 0.5,
            "vertical scroller must reserve its own layout gutter"
        )

        for _ in 0..<20 {
            PersistentVerticalScroller.configure(scrollView)
            try expect(
                scrollView.verticalScroller === nativeScroller,
                "repeated SwiftUI updates must not replace or retile the native scroller"
            )
        }

        print("Scrollbar checks passed (10/10); reserved gutter: \(reservedWidth) pt")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message) }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
