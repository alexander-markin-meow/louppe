import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class HotkeyTests: XCTestCase {
    private static var retainedHostingWindows: [NSWindow] = []

    func testArrowKeysNavigateGridEvenWhenCurrentItemIsVideo() {
        let store = readyStore(itemCount: 6, firstItemIsVideo: true)
        store.viewMode = .grid
        store.setGridColumnCount(3)
        let view = SessionView(store: store)

        let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
        XCTAssertTrue(
            view.handleKey(keyEvent(code: 124, modifiers: arrowFlags))
        ) // right
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(
            view.handleKey(keyEvent(code: 125, modifiers: arrowFlags))
        ) // down
        XCTAssertEqual(store.currentIndex, 4)
        XCTAssertTrue(
            view.handleKey(keyEvent(code: 126, modifiers: arrowFlags))
        ) // up
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(
            view.handleKey(keyEvent(code: 123, modifiers: arrowFlags))
        ) // left
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testReviewHotkeysStillRateAndAdvance() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: true)
        let view = SessionView(store: store)

        XCTAssertTrue(view.handleKey(keyEvent(code: 3, characters: "f")))
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)

        XCTAssertTrue(view.handleKey(keyEvent(code: 2, characters: "d")))
        XCTAssertEqual(store.items[1].rating, .no)
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testNumericHotkeysSetStarsWithoutChangingDecisionOrAdvancing() {
        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        store.rate(.yes, at: 0)

        XCTAssertTrue(view.handleKey(keyEvent(code: 21, characters: "4")))
        XCTAssertEqual(store.items[0].starRatingState, .stars(.four))
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 0)

        XCTAssertTrue(view.handleKey(keyEvent(code: 29, characters: "0")))
        XCTAssertEqual(store.items[0].starRatingState, .unrated)
        XCTAssertEqual(store.items[0].rating, .yes)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 23, characters: "5", modifiers: [.command])
            )
        )
        XCTAssertEqual(store.items[0].starRatingState, .unrated)
    }

    func testSpaceTogglesVideoButAdvancesFromPhoto() {
        let videoStore = readyStore(itemCount: 3, firstItemIsVideo: true)
        let videoView = SessionView(store: videoStore)

        XCTAssertTrue(videoView.handleKey(keyEvent(code: 49, characters: " ")))
        XCTAssertEqual(videoStore.currentIndex, 0)
        XCTAssertEqual(videoStore.videoPlayback.itemID, videoStore.items[0].id)
        XCTAssertTrue(videoStore.videoPlayback.isActive(videoStore.items[0]))

        let photoStore = readyStore(itemCount: 3, firstItemIsVideo: false)
        let photoView = SessionView(store: photoStore)

        XCTAssertTrue(photoView.handleKey(keyEvent(code: 49, characters: " ")))
        XCTAssertEqual(photoStore.currentIndex, 1)
        XCTAssertNil(photoStore.videoPlayback.itemID)
    }

    func testXTogglesClippingWarningsOnlyForSingleGalleryPhoto() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)

        XCTAssertTrue(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertTrue(store.showClippingWarnings)
        XCTAssertTrue(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertFalse(store.showClippingWarnings)

        store.viewMode = .grid
        XCTAssertFalse(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertFalse(store.showClippingWarnings)

        store.viewMode = .gallery
        store.selectAllVisible()
        XCTAssertFalse(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertFalse(store.showClippingWarnings)
    }

    func testXDoesNotToggleClippingWarningsForVideo() {
        let store = readyStore(itemCount: 2, firstItemIsVideo: true)
        let view = SessionView(store: store)

        XCTAssertFalse(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertFalse(store.showClippingWarnings)
    }

    func testDestructiveShortcutPassesThroughOutsideUnobstructedSessionContext() {
        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let commandDelete = keyEvent(
            code: 51,
            characters: "\u{7f}",
            modifiers: [.command]
        )
        let blockedContexts = [
            SessionKeyRoutingContext(
                sessionOwnsEvent: false,
                hasModalPresentation: false
            ),
            SessionKeyRoutingContext(
                sessionOwnsEvent: true,
                hasModalPresentation: true
            ),
            SessionKeyRoutingContext(
                sessionOwnsEvent: true,
                hasModalPresentation: false,
                focusedResponderOwnsText: true
            ),
        ]

        for context in blockedContexts {
            XCTAssertFalse(view.handleKey(commandDelete, context: context))
        }
        XCTAssertFalse(store.isFileOperationRunning)
        XCTAssertEqual(store.items.count, 2)
    }

    func testResponderRolesSeparateTextFromNativeControlNavigation() {
        XCTAssertTrue(
            SessionKeyRoutingContext.responderOwnsText(
                NSTextView()
            )
        )
        XCTAssertFalse(
            SessionKeyRoutingContext.responderOwnsText(
                NSSlider()
            )
        )
        XCTAssertFalse(
            SessionKeyRoutingContext.responderOwnsText(
                NSView()
            )
        )
        XCTAssertTrue(
            SessionKeyRoutingContext.responderOwnsNavigation(NSSlider())
        )
        XCTAssertTrue(
            SessionKeyRoutingContext.responderOwnsNavigation(NSView())
        )
        XCTAssertFalse(
            SessionKeyRoutingContext.responderOwnsNavigation(NSWindow())
        )
    }

    func testHostedSwiftUIButtonFocusStillAllowsCullingHotkeys() throws {
        let hostingView = NSHostingView(
            rootView: Button("Focused control") {}
                .frame(width: 200, height: 80)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let focusedControlProxy = try XCTUnwrap(hostingView.nextKeyView)
        XCTAssertTrue(window.makeFirstResponder(focusedControlProxy))
        let context = SessionKeyRoutingContext(
            eventWindow: window,
            eventWindowNumber: window.windowNumber,
            sessionWindow: window,
            keyWindow: window,
            modalWindow: nil
        )
        XCTAssertTrue(context.acceptsReviewShortcuts)
        XCTAssertFalse(context.acceptsNavigationShortcuts)

        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 3, characters: "f"),
                context: context
            )
        )
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 5, characters: "g"),
                context: context
            )
        )
        XCTAssertEqual(store.viewMode, .grid)
        let currentIndex = store.currentIndex
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 49, characters: " "),
                context: context
            ),
            "Space must stay with a keyboard-focused Button"
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 124,
                    modifiers: [.numericPad, .function]
                ),
                context: context
            ),
            "arrows must stay with a keyboard-focused control"
        )
        XCTAssertEqual(store.currentIndex, currentIndex)
        window.orderOut(nil)
        Self.retainedHostingWindows.append(window)
    }

    func testHostedSelectableTextRetainsEverySessionCommand() throws {
        let hostingView = NSHostingView(
            rootView: Text("Selectable metadata")
                .textSelection(.enabled)
                .frame(width: 240, height: 80)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let selectionProxy = try XCTUnwrap(hostingView.nextKeyView)
        XCTAssertTrue(window.makeFirstResponder(selectionProxy))
        let context = SessionKeyRoutingContext(
            eventWindow: window,
            eventWindowNumber: window.windowNumber,
            sessionWindow: window,
            keyWindow: window,
            modalWindow: nil
        )
        XCTAssertTrue(context.focusedResponderOwnsText)
        XCTAssertFalse(context.acceptsReviewShortcuts)
        XCTAssertFalse(context.acceptsNavigationShortcuts)

        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        store.rate(.yes, at: 0)
        let originalRatings = store.items.map(\.rating)
        let view = SessionView(store: store)
        for event in [
            keyEvent(code: 3, characters: "f"),
            keyEvent(code: 0, characters: "a", modifiers: [.command]),
            keyEvent(code: 14, characters: "e", modifiers: [.command]),
            keyEvent(code: 6, characters: "z", modifiers: [.command]),
            keyEvent(
                code: 51,
                characters: "\u{7f}",
                modifiers: [.command]
            ),
        ] {
            XCTAssertFalse(view.handleKey(event, context: context))
        }
        XCTAssertEqual(store.items.map(\.rating), originalRatings)
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertFalse(store.isExportPresented)
        XCTAssertFalse(store.isFileOperationRunning)

        window.orderOut(nil)
        Self.retainedHostingWindows.append(window)
    }

#if DEBUG
    func testInstalledMonitorRoutesWindowEventsAndIsRemovedWithSessionView() throws {
        _ = NSApplication.shared
        let baselineMonitorCount =
            SessionKeyMonitorTestProbe.activeMonitorCount
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let container = NSView(frame: frame)
        var sessionHost: NSHostingView<SessionView>? = NSHostingView(
            rootView: SessionView(store: store)
        )
        sessionHost?.frame = frame
        if let sessionHost {
            container.addSubview(sessionHost)
        }

        let button = NSButton(
            title: "Focused control",
            target: nil,
            action: nil
        )
        button.refusesFirstResponder = false
        button.frame = NSRect(x: 12, y: 12, width: 140, height: 28)
        container.addSubview(button)

        let selectableText = NSTextView(
            frame: NSRect(x: 170, y: 12, width: 180, height: 28)
        )
        selectableText.string = "Selectable metadata"
        selectableText.isEditable = false
        selectableText.isSelectable = true
        selectableText.drawsBackground = false
        container.addSubview(selectableText)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        // XCTest bundles cannot become the process's active app, so AppKit
        // never assigns their otherwise-real test window to NSApp.keyWindow.
        // The debug-only override supplies only that unavailable fact; event
        // monitoring, window-number matching, SessionWindowReader discovery,
        // first responders, and teardown all remain the production path.
        SessionKeyMonitorTestProbe.overrideKeyWindow(with: window)
        defer {
            sessionHost?.removeFromSuperview()
            sessionHost = nil
            window.orderOut(nil)
            SessionKeyMonitorTestProbe.overrideKeyWindow(with: nil)
        }

        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount + 1
        })

        // Exercise the installed NSEvent monitor, its live NSWindow lookup,
        // and its non-text-control focus policy rather than calling handleKey.
        XCTAssertTrue(window.makeFirstResponder(button))
        sendKeyEvent(code: 3, characters: "f", in: window)
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)
        sendKeyEvent(code: 5, characters: "g", in: window)
        XCTAssertEqual(store.viewMode, .grid)

        // Selectable text owns every key. If the live routing misclassifies
        // this responder, D would rate item 1 and Command-A would select media.
        XCTAssertTrue(window.makeFirstResponder(selectableText))
        XCTAssertTrue(
            SessionKeyRoutingContext.responderOwnsText(
                window.firstResponder
            )
        )
        sendKeyEvent(code: 2, characters: "d", in: window)
        sendKeyEvent(
            code: 0,
            characters: "a",
            modifiers: [.command],
            in: window
        )
        XCTAssertEqual(store.items[1].rating, .undecided)
        XCTAssertTrue(store.selectedIndices.isEmpty)

        // Removing the hosted SessionView must unregister its process-wide
        // monitor. Dispatching the same key afterward must leave state alone.
        sessionHost?.removeFromSuperview()
        sessionHost = nil
        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount
        })
        XCTAssertTrue(window.makeFirstResponder(button))
        sendKeyEvent(code: 2, characters: "d", in: window)
        XCTAssertEqual(store.items[1].rating, .undecided)
    }
#endif

    func testTextEditorBlocksUntilEditingFocusEnds() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextField(
            frame: NSRect(x: 20, y: 20, width: 200, height: 24)
        )
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let editingContext = SessionKeyRoutingContext(
            eventWindow: window,
            eventWindowNumber: window.windowNumber,
            sessionWindow: window,
            keyWindow: window,
            modalWindow: nil
        )
        XCTAssertFalse(editingContext.acceptsReviewShortcuts)

        XCTAssertTrue(window.makeFirstResponder(nil))

        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 3, characters: "f"),
                context: SessionKeyRoutingContext(
                    eventWindow: window,
                    eventWindowNumber: window.windowNumber,
                    sessionWindow: window,
                    keyWindow: window,
                    modalWindow: nil
                )
            )
        )
        XCTAssertEqual(store.items[0].rating, .yes)
        window.orderOut(nil)
        Self.retainedHostingWindows.append(window)
    }

    func testEmptySessionCannotPresentExportFromToolbarOrHotkeys() {
        let store = readyStore(itemCount: 1, firstItemIsVideo: false)
        let movedIDs = store.items.map(\.id)
        XCTAssertTrue(store.exportWillStart(mode: .move))
        store.finishExport(
            mode: .move,
            movedIDs: movedIDs,
            requiresRecovery: false
        )
        let view = SessionView(store: store)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertFalse(store.canExport)
        XCTAssertFalse(store.canCleanUp)
        store.presentExport()
        XCTAssertFalse(store.isExportPresented)
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 14, characters: "e"),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 51,
                    characters: "\u{7f}",
                    modifiers: [.command]
                ),
                context: .focusedSession
            ),
            "an unavailable destructive action must not swallow Command-Delete"
        )
        XCTAssertFalse(store.isExportPresented)
        XCTAssertFalse(store.isFileOperationRunning)
    }

    func testPresentedSessionUIPassesThroughBeforeCommandShortcuts() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let commandA = keyEvent(
            code: 0,
            characters: "a",
            modifiers: [.command]
        )

        store.isExportPresented = true
        XCTAssertFalse(view.handleKey(commandA, context: .focusedSession))
        XCTAssertTrue(store.selectedIndices.isEmpty)

        store.isExportPresented = false
        store.isFilterPresented = true
        XCTAssertFalse(view.handleKey(commandA, context: .focusedSession))
        XCTAssertTrue(store.selectedIndices.isEmpty)
    }

    func testLegacyMigrationConfirmationBlocksSessionHotkeys() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        store.presentLegacySessionMigrationConfirmationForTesting()

        XCTAssertTrue(store.isSessionCommandPresentationActive)
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 3, characters: "f"),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command]
                ),
                context: .focusedSession
            )
        )
        XCTAssertEqual(store.items[0].rating, .undecided)
        XCTAssertFalse(store.isExportPresented)
    }

    func testMenuEquivalentKeysUseTheSameFocusedSessionGate() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let commandE = keyEvent(
            code: 14,
            characters: "e",
            modifiers: [.command]
        )

        XCTAssertFalse(view.handleKey(commandE, context: .blocked))
        XCTAssertFalse(store.isExportPresented)

        XCTAssertTrue(view.handleKey(commandE, context: .focusedSession))
        XCTAssertTrue(store.isExportPresented)

        store.isExportPresented = false
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command, .option]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(store.isExportPresented)
    }

    func testAppCommandsRemainAvailableFromNonTextControlFocus() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let focusedButton = SessionKeyRoutingContext(
            sessionOwnsEvent: true,
            hasModalPresentation: false,
            focusedResponderOwnsText: false,
            focusedResponderOwnsNavigation: true
        )

        XCTAssertTrue(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command]
                ),
                context: focusedButton
            )
        )
        XCTAssertTrue(store.isExportPresented)
    }

    func testTextEditingRetainsStandardCommandShortcuts() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let textEditing = SessionKeyRoutingContext(
            sessionOwnsEvent: true,
            hasModalPresentation: false,
            focusedResponderOwnsText: true,
            focusedResponderOwnsNavigation: true
        )

        for event in [
            keyEvent(code: 14, characters: "e", modifiers: [.command]),
            keyEvent(code: 6, characters: "z", modifiers: [.command]),
            keyEvent(code: 0, characters: "a", modifiers: [.command]),
        ] {
            XCTAssertFalse(view.handleKey(event, context: textEditing))
        }
        XCTAssertFalse(store.isExportPresented)
        XCTAssertTrue(store.selectedIndices.isEmpty)
    }

    func testOnlyExactDocumentedModifiersReachSessionCommands() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 0,
                    characters: "a",
                    modifiers: [.command, .option]
                ),
                context: .focusedSession
            )
        )
        XCTAssertTrue(store.selectedIndices.isEmpty)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.control, .option]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.function]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.help]
                ),
                context: .focusedSession
            )
        )
        XCTAssertTrue(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.capsLock]
                ),
                context: .focusedSession
            )
        )
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.capsLock]
                ),
                context: SessionKeyRoutingContext(
                    sessionOwnsEvent: true,
                    hasModalPresentation: false,
                    isVoiceOverEnabled: true
                )
            ),
            "Caps Lock must remain VoiceOver's modifier while it is running"
        )

        XCTAssertTrue(
            view.handleKey(
                keyEvent(
                    code: 2,
                    characters: "D",
                    modifiers: [.shift],
                    charactersIgnoringModifiers: "d"
                ),
                context: .focusedSession
            )
        )
        XCTAssertEqual(store.items[1].rating, .no)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 48,
                    characters: "\t",
                    modifiers: [.shift]
                ),
                context: .focusedSession
            ),
            "Shift-Tab must remain native reverse focus navigation"
        )

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 51,
                    characters: "\u{7f}",
                    modifiers: [.command, .shift]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(store.isFileOperationRunning)

        XCTAssertTrue(
            view.handleKey(
                keyEvent(
                    code: 0,
                    characters: "a",
                    modifiers: [.command]
                ),
                context: .focusedSession
            )
        )
        XCTAssertEqual(store.selectedIndices.count, 3)
    }

    func testFileOperationPassesThroughModifiersSheetsAndUnknownKeys() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        defer {
            store.finishExport(
                mode: .copy,
                movedIDs: [],
                requiresRecovery: false
            )
        }

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.control, .option]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 11, characters: "b"),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 48, characters: "\t", modifiers: [.shift]),
                context: .focusedSession
            )
        )

        let initialMode = store.viewMode
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 5, characters: "g"),
                context: SessionKeyRoutingContext(
                    sessionOwnsEvent: true,
                    hasModalPresentation: true
                )
            )
        )
        XCTAssertEqual(store.viewMode, initialMode)

        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 5, characters: "g"),
                context: .focusedSession
            )
        )
        XCTAssertNotEqual(store.viewMode, initialMode)
    }

    private func readyStore(itemCount: Int, firstItemIsVideo: Bool) -> SessionStore {
        _ = NSApplication.shared
        let store = SessionStore()
        store.items = (0..<itemCount).map { index in
            let isVideo = firstItemIsVideo && index == 0
            let ext = isVideo ? "MOV" : "JPG"
            let id = "ITEM_\(index).\(ext)"
            return PhotoItem(
                id: id,
                primaryURL: URL(fileURLWithPath: "/tmp/\(id)"),
                pairedURL: nil,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                mediaKind: isVideo ? .video : .photo,
                duration: isVideo ? 2 : nil,
                videoIsPlayable: isVideo,
                fileSize: 1
            )
        }
        // A sort change rebuilds the same visibility structures populated by
        // a real folder scan, while keeping the test independent of disk I/O.
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        return store
    }

    private func keyEvent(
        code: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        charactersIgnoringModifiers: String? = nil
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers:
                charactersIgnoringModifiers ?? characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    private func sendKeyEvent(
        code: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
        NSApp.sendEvent(event)
    }

    private func waitForCondition(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        return condition()
    }
}
