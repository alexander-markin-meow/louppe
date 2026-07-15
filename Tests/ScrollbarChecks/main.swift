import AppKit

@main
struct ScrollbarChecks {
    @MainActor
    static func main() throws {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400)
        )
        scrollView.documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 1_000)
        )

        PersistentVerticalScroller.configure(scrollView)

        try expect(scrollView.scrollerStyle == .legacy, "scroller must use the non-overlay legacy style")
        try expect(scrollView.hasVerticalScroller, "vertical scroller must be installed")
        try expect(!scrollView.autohidesScrollers, "vertical scroller must never autohide")
        try expect(scrollView.verticalScroller?.isHidden == false, "vertical scroller must remain visible")
        try expect(scrollView.verticalScroller?.isEnabled == true, "vertical scroller must be active for overflowing content")

        let reservedWidth = scrollView.bounds.width - scrollView.contentSize.width
        try expect(
            abs(reservedWidth - PersistentVerticalScroller.gutterWidth) < 0.5,
            "vertical scroller must reserve its own layout gutter"
        )
        print("Scrollbar checks passed (6/6); reserved gutter: \(reservedWidth) pt")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message) }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
