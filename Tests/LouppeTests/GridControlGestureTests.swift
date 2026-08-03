import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class GridControlGestureTests: XCTestCase {
    private static var retainedWindows: [NSWindow] = []

    func testEmbeddedControlDragDoesNotStartAncestorRubberBand() throws {
        _ = NSApplication.shared
        let state = HostedGridControlDragState()
        let tileFrame = CGRect(x: 0, y: 0, width: 170, height: 170)
        let hostingView = NSHostingView(
            rootView: HostedGridControlDragFixture(
                state: state,
                tileFrames: [0: tileFrame]
            )
        )
        hostingView.frame = tileFrame
        let window = NSWindow(
            contentRect: tileFrame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // The centered native Button stands in for GridCell's Play control.
        // Ten points exceeds the Grid's eight-point drag threshold while the
        // pointer remains inside the Button's 40-point target.
        try sendDrag(
            in: window,
            from: CGPoint(x: 85, y: 85),
            to: CGPoint(x: 95, y: 85),
            firstEventNumber: 1
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(state.buttonActivations, 1)
        XCTAssertGreaterThan(
            state.ancestorDragEvaluations,
            0,
            "the hosted ancestor gesture must observe the control-origin drag"
        )
        XCTAssertEqual(
            state.rubberBandChanges,
            0,
            "a drag owned by an embedded control must never mutate selection"
        )
        window.orderOut(nil)
        Self.retainedWindows.append(window)
    }

    func testNativeRatingButtonCountsEveryClickInMultiClickSequence() throws {
        _ = NSApplication.shared
        let state = HostedGridControlDragState()
        let store = readyStore()
        let tileFrame = CGRect(x: 0, y: 0, width: 170, height: 170)
        let hostingView = NSHostingView(
            rootView: HostedGridControlDragFixture(
                state: state,
                tileFrames: [0: tileFrame],
                controlPlacement: .rating
            ) {
                GridCellActions(store: store, index: 0).cycleRating()
            }
        )
        hostingView.frame = tileFrame
        let window = NSWindow(
            contentRect: tileFrame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // SwiftUI's top-trailing 40-point target maps to the upper-right of
        // this AppKit window. Native clickCount values 2 and 3 must remain
        // intentional activations, even with the Grid's ancestor drag gesture.
        let ratingPoint = CGPoint(x: 150, y: 150)
        try sendClick(
            in: window,
            at: ratingPoint,
            firstEventNumber: 10,
            clickCount: 1
        )
        XCTAssertEqual(store.items[0].rating, .yes)
        try sendClick(
            in: window,
            at: ratingPoint,
            firstEventNumber: 12,
            clickCount: 2
        )
        XCTAssertEqual(store.items[0].rating, .no)
        try sendClick(
            in: window,
            at: ratingPoint,
            firstEventNumber: 14,
            clickCount: 3
        )

        XCTAssertEqual(state.buttonActivations, 3)
        XCTAssertEqual(store.items[0].rating, .undecided)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(state.rubberBandChanges, 0)
        window.orderOut(nil)
        Self.retainedWindows.append(window)
    }

    func testGridPhotoClickSelectsImmediatelyAndSecondClickOpensGallery() throws {
        _ = NSApplication.shared
        let state = HostedImmediateGridClickState()
        let store = readyStore()
        store.viewMode = .grid
        let frame = CGRect(x: 0, y: 0, width: 170, height: 170)
        let hostingView = NSHostingView(
            rootView: HostedImmediateGridClickFixture(
                state: state,
                store: store,
                index: 1
            )
        )
        hostingView.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // A drag remains owned by the Grid's simultaneous rubber-band gesture
        // and must not accidentally commit the initial photo click.
        try sendDrag(
            in: window,
            from: CGPoint(x: 60, y: 85),
            to: CGPoint(x: 80, y: 85),
            firstEventNumber: 30
        )
        XCTAssertGreaterThan(state.dragChanges, 0)
        XCTAssertEqual(store.currentIndex, 0)

        // Modifier ownership comes from this exact mouse event, not from
        // delayed global modifier state after the click has finished.
        try sendClick(
            in: window,
            at: CGPoint(x: 85, y: 85),
            firstEventNumber: 38,
            clickCount: 1,
            modifierFlags: [.command],
            settleRunLoop: false
        )
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.selectedIndices, [0, 1])
        store.clearSelection()

        // Do not run the run loop after mouse-up: selection must be committed
        // synchronously, well before AppKit's double-click interval expires.
        try sendClick(
            in: window,
            at: CGPoint(x: 85, y: 85),
            firstEventNumber: 40,
            clickCount: 1,
            settleRunLoop: false
        )
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.viewMode, .grid)

        // The second click in the sequence opens the item that the first click
        // already selected; it never delays or repeats the selection action.
        try sendClick(
            in: window,
            at: CGPoint(x: 85, y: 85),
            firstEventNumber: 42,
            clickCount: 2,
            settleRunLoop: false
        )
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.viewMode, .gallery)

        window.orderOut(nil)
        Self.retainedWindows.append(window)
    }

    private func sendDrag(
        in window: NSWindow,
        from start: CGPoint,
        to end: CGPoint,
        firstEventNumber: Int
    ) throws {
        window.sendEvent(
            try mouseEvent(
                .leftMouseDown,
                at: start,
                in: window,
                eventNumber: firstEventNumber,
                pressure: 1
            )
        )
        window.sendEvent(
            try mouseEvent(
                .leftMouseDragged,
                at: end,
                in: window,
                eventNumber: firstEventNumber + 1,
                pressure: 1
            )
        )
        window.sendEvent(
            try mouseEvent(
                .leftMouseUp,
                at: end,
                in: window,
                eventNumber: firstEventNumber + 2,
                pressure: 0
            )
        )
    }

    private func sendClick(
        in window: NSWindow,
        at point: CGPoint,
        firstEventNumber: Int,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags = [],
        settleRunLoop: Bool = true
    ) throws {
        window.sendEvent(
            try mouseEvent(
                .leftMouseDown,
                at: point,
                in: window,
                eventNumber: firstEventNumber,
                pressure: 1,
                clickCount: clickCount,
                modifierFlags: modifierFlags
            )
        )
        window.sendEvent(
            try mouseEvent(
                .leftMouseUp,
                at: point,
                in: window,
                eventNumber: firstEventNumber + 1,
                pressure: 0,
                clickCount: clickCount,
                modifierFlags: modifierFlags
            )
        )
        if settleRunLoop {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in window: NSWindow,
        eventNumber: Int,
        pressure: Float,
        clickCount: Int = 1,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: clickCount,
                pressure: pressure
            )
        )
    }

    private func readyStore() -> SessionStore {
        let store = SessionStore()
        store.items = [
            PhotoItem(
                id: "RATING.JPG",
                primaryURL: URL(fileURLWithPath: "/tmp/RATING.JPG"),
                pairedURL: nil,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                fileSize: 1
            ),
            PhotoItem(
                id: "SECOND.JPG",
                primaryURL: URL(fileURLWithPath: "/tmp/SECOND.JPG"),
                pairedURL: nil,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                fileSize: 1
            )
        ]
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        return store
    }
}

@MainActor
private final class HostedImmediateGridClickState: ObservableObject {
    @Published var dragChanges = 0
}

private struct HostedImmediateGridClickFixture: View {
    @ObservedObject var state: HostedImmediateGridClickState
    @ObservedObject var store: SessionStore
    let index: Int

    var body: some View {
        GridImmediateClickSurface(
            onSingleClick: { modifiers in
                GridCellActions(
                    store: store,
                    index: index
                ).selectPhoto(modifiers: modifiers)
            },
            onDoubleClick: {
                GridCellActions(
                    store: store,
                    index: index
                ).openInGallery()
            }
        )
        .frame(width: 170, height: 170)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in state.dragChanges += 1 }
        )
    }
}

@MainActor
private final class HostedGridControlDragState: ObservableObject {
    @Published var buttonActivations = 0
    @Published var ancestorDragEvaluations = 0
    @Published var rubberBandChanges = 0
}

private struct HostedGridControlDragFixture: View {
    @ObservedObject var state: HostedGridControlDragState
    let tileFrames: [Int: CGRect]
    var controlPlacement: HostedGridControlPlacement = .center
    var onActivation: () -> Void = {}

    var body: some View {
        ZStack(alignment: controlPlacement == .rating ? .topTrailing : .center) {
            Color.gray
            Button {
                state.buttonActivations += 1
                onActivation()
            } label: {
                Color.green
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(controlPlacement == .rating ? 2 : 0)
        }
        .frame(width: 170, height: 170)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .local)
                .onChanged { value in
                    state.ancestorDragEvaluations += 1
                    guard GridRubberBandHitTest.shouldTrackCanvasDrag(
                        startingAt: value.startLocation,
                        tileFrames: tileFrames,
                        playableVideoIndices: [0]
                    ) else { return }
                    state.rubberBandChanges += 1
                }
        )
    }
}

private enum HostedGridControlPlacement {
    case center
    case rating
}
