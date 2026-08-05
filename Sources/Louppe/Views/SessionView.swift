import SwiftUI
import AppKit

/// The active culling session: hosts the Gallery and Grid views, the
/// toolbar, the export sheet, and all single-key hotkeys.
///
/// Hotkey map (README's table must stay in sync with `handleKey`):
///   F yes · D no · S 100% zoom · A phone-size zoom · R clear all
///   Q browser · W info panel · X clipping warnings · E export
///   Space video play/pause (photo: next)
///   ←/→ prev/next
///   ↑/↓ prev/next in the Gallery view · same-column photo in the Grid view
///   Tab/G switch view · Z/⌘Z undo · ⌘+/⌘− grid size
///   ⌘A select all · ⌘⇧←/→ select to first/last · Esc clear selection
///   ⌘⌫ trash selection (no confirmation — ⌘Z restores)
///   (⇧-click range and ⌘-click add/remove live in the thumbnail views)
struct SessionView: View {
    @ObservedObject var store: SessionStore
    @State private var keyMonitor: Any?
    @State private var sessionWindowReference = SessionWindowReference()

    var body: some View {
        mainContent
            .overlay { cleanUpProgressOverlay }
            .toolbar { toolbarContent }
            .navigationTitle("")
            .focusedSceneValue(\.louppeSessionStore, store)
            .background {
                SessionWindowReader { window in
                    sessionWindowReference.window = window
                }
            }
            .sheet(isPresented: $store.isExportPresented) {
                ExportView(store: store)
            }
            .alert("Clear All Ratings?", isPresented: $store.isClearAllRatingsConfirmationPresented) {
                Button("Clear All Ratings", role: .destructive) {
                    store.clearAllRatings()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(clearAllRatingsMessage)
            }
            .alert(
                legacyMigrationTitle,
                isPresented: legacyMigrationConfirmationPresented
            ) {
                if store.legacySessionMigrationMissingFileCount > 0 {
                    Button(legacyMissingFilesActionTitle, role: .destructive) {
                        store.confirmLegacySessionMigration()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Use Saved Ratings") {
                        store.confirmLegacySessionMigration()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Close Folder", role: .cancel) {
                    store.closeLegacySessionWithoutMigrating()
                }
            } message: {
                Text(legacyMigrationMessage)
            }
            .confirmationDialog(
                cleanUpTitle,
                isPresented: isCleanUpConfirmPresented,
                titleVisibility: .visible,
                presenting: store.pendingCleanUp
            ) { mode in
                Button("Move to Trash", role: .destructive) {
                    store.performCleanUp(mode)
                }
                Button("Cancel", role: .cancel) {}
            } message: { mode in
                Text(cleanUpMessage(for: mode))
            }
            .alert("Clean Up", isPresented: isCleanUpErrorPresented) {
                Button("OK") { store.cleanUpError = nil }
            } message: {
                Text(store.cleanUpError ?? "")
            }
            .onAppear(perform: installKeyMonitor)
            .onDisappear(perform: removeKeyMonitor)
    }

    // MARK: - Clean up confirmation

    private var clearAllRatingsMessage: String {
        let count = store.ratedCount
        let items = count == 1 ? "1 item" : "\(count) items"
        return "This will remove the Yes or No rating from \(items). You can undo it with ⌘Z."
    }

    private var isCleanUpConfirmPresented: Binding<Bool> {
        Binding(
            get: { store.pendingCleanUp != nil },
            set: { if !$0 { store.pendingCleanUp = nil } }
        )
    }

    private var legacyMigrationConfirmationPresented: Binding<Bool> {
        Binding(
            get: {
                store.isLegacySessionMigrationConfirmationPresented
            },
            // Only the two explicit alert actions may resolve this gate.
            set: { _ in }
        )
    }

    private var legacyMigrationTitle: String {
        switch store.legacySessionMigrationMissingFileCount {
        case 0:
            return "Use Saved Ratings?"
        case 1:
            return "A Saved File Is Missing"
        default:
            return "Saved Files Are Missing"
        }
    }

    private var legacyMissingFilesActionTitle: String {
        store.legacySessionMigrationMissingFileCount == 1
            ? "Open Folder and Forget Missing Item"
            : "Open Folder and Forget Missing Items"
    }

    private var legacyMigrationMessage: String {
        let count = store.legacySessionMigrationMissingFileCount
        guard count > 0 else {
            return "This folder contains ratings saved by an older version of Louppe. "
                + "Every saved filename is present, but the older session cannot prove that the files are the exact originals. "
                + "Use Saved Ratings upgrades the session and binds each rating to its physical file. "
                + "Close Folder leaves the existing session untouched."
        }
        let files = count == 1
            ? "1 file that is"
            : "\(count) files that are"
        let availability = count == 1
            ? "it was deleted intentionally or is temporarily unavailable"
            : "they were deleted intentionally or are temporarily unavailable"
        let ratings = count == 1
            ? "that old saved rating"
            : "those old saved ratings"
        var message = "This older Louppe session has saved ratings for \(files) no longer in the folder. "
            + "Louppe cannot tell whether \(availability). "
            + "Open Folder and Forget Missing \(count == 1 ? "Item" : "Items") removes only \(ratings), keeps the ratings for files still here, and upgrades the session. "
            + "Close Folder changes nothing."
        if store.legacySessionMigrationUsesUnownedBackup {
            message += " These ratings also came from an older local backup that is not tied to this exact folder; opening will bind the surviving same-name ratings to the files currently here."
        }
        return message
    }

    private var isCleanUpErrorPresented: Binding<Bool> {
        Binding(
            get: { store.cleanUpError != nil },
            set: { if !$0 { store.cleanUpError = nil } }
        )
    }

    private var cleanUpTitle: String {
        guard let mode = store.pendingCleanUp else { return "" }
        let counts = store.cleanUpCounts(for: mode)
        switch mode {
        case .selection:
            return "Move \(itemsPhrase(counts.photos)) to the Trash?"
        case .trashNo:
            return "Move \(itemsPhrase(counts.photos)) marked “No” to the Trash?"
        case .keepOnlyYes:
            return "Move \(itemsPhrase(counts.photos)) not marked “Yes” to the Trash?"
        }
    }

    private func cleanUpMessage(for mode: CleanUpMode) -> String {
        let counts = store.cleanUpCounts(for: mode)
        let files = counts.files == 1 ? "1 file" : "\(counts.files) files"
        let space = ByteCountFormatter.string(fromByteCount: counts.bytes, countStyle: .file)
        var parts = [
            "\(files) will be moved to the Trash (a RAW+JPEG pair counts as two), totaling about \(space). Immediately afterward, you can undo during this open session while the files remain in the Trash. Emptying the Trash permanently deletes them and may reclaim approximately that space."
        ]
        switch mode {
        case .selection:
            parts.append("Only the selected items will leave the folder; everything else stays.")
        case .trashNo:
            parts.append("Among the items being considered, items marked “Yes” and unrated items stay in the folder.")
        case .keepOnlyYes:
            parts.append("Among the items being considered, only those marked “Yes” stay in the folder.")
        }
        // Spell out the rating-based scope so nothing outside it is trashed
        // (or spared) by surprise. A direct selection is already explicit.
        if mode != .selection {
            switch store.cleanUpScope {
            case .all:
                if store.filter.isActive {
                    parts.append("All \(store.items.count) items in the folder are considered, including the ones the filter currently hides.")
                }
            case .filtered:
                if store.filter.isActive {
                    let hidden = store.items.count - store.visibleIndices.count
                    parts.append("Only the \(store.visibleIndices.count) items the filter shows are considered — the \(hidden) hidden ones aren't touched.")
                }
            case .selected:
                let count = store.cleanUpScopeCount(for: .selected)
                let phrase = count == 1 ? "1 selected item is" : "\(count) selected items are"
                parts.append("Only \(phrase) considered — every unselected item stays in the folder.")
            }
        }
        return parts.joined(separator: "\n")
    }

    private func itemsPhrase(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    private var subtitle: String {
        guard !store.items.isEmpty else { return "" }
        let position = store.visibleIndices.isEmpty
            ? 0
            : (store.currentVisiblePosition ?? 0) + 1
        var text = "\(position) of \(store.visibleIndices.count)"
        if store.filter.isActive {
            text += " (of \(store.items.count) total)"
        }
        text += "  ·  ✓ \(store.yesCount)  ✗ \(store.noCount)  · \(store.undecidedCount) left"
        if store.mixedCount > 0 {
            text += "  ·  \(store.mixedCount) mixed"
        }
        if store.selectedIndices.count > 1 {
            text += "  ·  \(store.selectedIndices.count) selected"
        }
        return text
    }

    private var statusText: some View {
        HStack(spacing: 8) {
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            // Background-work spinner. Always present (just invisible when
            // idle) so the status text doesn't shift when it appears.
            ProgressView()
                .controlSize(.small)
                .opacity(
                    store.fullImageLoads > 0
                        || store.isChangingRawJPEGPairingMode ? 1 : 0
                )
                .accessibilityLabel(
                    store.isChangingRawJPEGPairingMode
                        ? "Preparing separate JPEG metadata"
                        : "Loading photo preview"
                )
                .accessibilityHidden(
                    store.fullImageLoads == 0
                        && !store.isChangingRawJPEGPairingMode
                )
        }
        .help("Review progress and rating totals")
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            Group {
                switch store.viewMode {
                case .gallery:
                    GalleryView(store: store)
                case .grid:
                    GridView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The Info panel is shared by both modes. Keeping it outside the
            // mode switch preserves its metadata/histogram tasks instead of
            // tearing them down and reopening the RAW on every toggle.
            if store.showMetadataPanel, let item = store.currentItem {
                Divider()
                MetadataPanel(store: store, item: item)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    @ViewBuilder
    private var cleanUpProgressOverlay: some View {
        if let progress = store.cleanUpProgress {
            VStack(spacing: 8) {
                Text(progress.title)
                    .font(.headline)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 280)
                Text("\(progress.done) of \(progress.total) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(18)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .shadow(radius: 12)
            // The overlay reports progress without blocking scrolling or view
            // inspection. SessionStore separately guards unsafe mutations.
            .allowsHitTesting(false)
        }
    }

    // MARK: - Toolbar

    /// Toolbar order and Liquid Glass groups (2026-07-15):
    /// {folder} {filter · sort · view picker} = status =
    /// {undo · clear all} {browser · info} {clean up} {export}.
    /// On macOS 26, fixed ToolbarSpacers are Apple's native separator between
    /// neighbouring glass groups. Earlier systems keep the same control order.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Current folder: click it to return to the start screen and pick
            // another folder (the session is saved first).
            Button {
                store.closeSession()
            } label: {
                Label(store.sourceFolder?.lastPathComponent ?? "Folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(store.isFileOperationRunning)
            .help("Choose another media folder (⌘O)")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .navigation)
        }

        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.isFilterPresented.toggle()
            } label: {
                Image(systemName: store.filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(store.filter.isActive ? Color.louppeAccent : Color.primary)
            }
            .popover(isPresented: $store.isFilterPresented, arrowEdge: .bottom) {
                FilterView(store: store)
            }
            .accessibilityLabel("Filter Media")
            .accessibilityValue(store.filter.isActive ? "Active" : "Not active")
            .help("Filter media by date, type, duration, subfolder, camera, or lens")

            Button {
                store.isSortPresented.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .popover(isPresented: $store.isSortPresented, arrowEdge: .bottom) {
                SortView(store: store)
            }
            .accessibilityLabel("Sort Media")
            .help("Sort media by date, name, type, duration, or metadata")

            Picker("View", selection: $store.viewMode) {
                Image(systemName: "photo")
                    .accessibilityLabel("Gallery")
                    .tag(ViewMode.gallery)
                Image(systemName: "square.grid.3x3")
                    .accessibilityLabel("Grid")
                    .tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Switch between Gallery and Grid views (Tab or G)")
        }

        // Session status stays centered and opts out of a glass capsule.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                statusText
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                statusText
            }
        }

        ToolbarItemGroup {
            Button {
                store.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(store.isFileOperationRunning || !store.canUndo)
            .accessibilityLabel("Undo")
            .help("Undo the last rating or clean-up (Z or ⌘Z)")
            Button {
                store.requestClearAllRatings()
            } label: {
                Image(systemName: "eraser")
            }
            .disabled(store.isFileOperationRunning || store.ratedCount == 0)
            .accessibilityLabel("Clear All Ratings")
            .help("Clear all ratings (R)")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItemGroup {
            // The Browser toggle leaves the toolbar entirely while the Grid
            // is showing — the column it controls exists only in the Gallery.
            if store.viewMode == .gallery {
                Button {
                    withAnimation { store.toggleBrowser() }
                } label: {
                    Image(systemName: store.showBrowser ? "sidebar.squares.left" : "sidebar.left")
                }
                .accessibilityLabel(store.showBrowser ? "Hide Browser" : "Show Browser")
                .help("Show or hide the Browser in the Gallery view (Q)")
            }

            Button {
                withAnimation { store.showMetadataPanel.toggle() }
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel(
                store.showMetadataPanel ? "Hide Media Information" : "Show Media Information"
            )
            .help("Show or hide media information (W)")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        cleanUpAndExportToolbarContent
    }

    /// Kept as a nested builder so the parent toolbar stays below Swift 5.9's
    /// result-builder arity limit while these remain two distinct capsules.
    @ToolbarContentBuilder
    private var cleanUpAndExportToolbarContent: some ToolbarContent {
        // Clean Up sits in its own capsule between inspection controls and
        // Export. The menu body is shared with the File menu. Clean Up is the
        // app's only Trash path; Export's explicit Move mode can instead move
        // originals to a photographer-chosen destination.
        ToolbarItem {
            Menu {
                CleanUpMenuItems(store: store)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!store.canCleanUp)
            .menuIndicator(.hidden)
            .tint(Color.primary)
            .accessibilityLabel("Clean Up")
            .help("Choose items to move to the Trash")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        // Export: its own prominent purple button. Use a bare Image (not a
        // Label with hidden text) so the icon centers in the circle instead
        // of being nudged aside by reserved label space.
        ToolbarItem {
            Button {
                store.presentExport()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    // Nudge up a touch to visually center the share glyph.
                    .offset(y: -1)
            }
            .disabled(!store.canExport)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(Color.louppeAccent)
            .accessibilityLabel("Export Media")
            .help("Export media by rating — copy or move it to a folder (E or ⌘E)")
        }
    }

    // MARK: - Keyboard shortcuts

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        guard let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { event in
                let context = liveKeyRoutingContext(for: event)
                if handleKey(event, context: context) { return nil }
                return event
            }
        ) else { return }
        keyMonitor = monitor
#if DEBUG
        SessionKeyMonitorTestProbe.didInstall()
#endif
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
#if DEBUG
            SessionKeyMonitorTestProbe.didRemove()
#endif
        }
        sessionWindowReference.window = nil
    }

    /// Internal compatibility entry point for focused logic tests that use
    /// synthetic events without an AppKit window. The installed event monitor
    /// always calls the context-aware overload below.
    func handleKey(_ event: NSEvent) -> Bool {
        handleKey(event, context: .focusedSession)
    }

    /// Routes one event only after its window, presentation, and focus context
    /// has proved that the active session owns keyboard input.
    func handleKey(
        _ event: NSEvent,
        context: SessionKeyRoutingContext
    ) -> Bool {
        guard context.sessionOwnsEvent,
              !context.hasModalPresentation,
              !store.isSessionCommandPresentationActive,
              case .ready = store.phase
        else {
            return false
        }

        var modifiers = normalizedShortcutModifiers(for: event)
        // Caps Lock is harmless capitalization during ordinary culling, but
        // it can also be VoiceOver's command modifier. When VoiceOver is
        // running, preserve that ownership instead of interpreting the chord.
        if !context.isVoiceOverEnabled {
            modifiers.remove(.capsLock)
        }
        let unsupportedReviewModifiers: NSEvent.ModifierFlags = [
            .command,
            .option,
            .control,
            .function,
            .help,
            .numericPad,
            .capsLock,
        ]
        let acceptsReviewModifiers = modifiers
            .intersection(unsupportedReviewModifiers)
            .isEmpty
        // Shift is accepted for letter shortcuts so an uppercase F/D/G still
        // works, but Shift-Tab and Shift-arrow belong to native focus and
        // selection navigation rather than changing the photo session.
        let acceptsNavigationModifiers =
            acceptsReviewModifiers && !modifiers.contains(.shift)

        if store.isFileOperationRunning {
            // Only unmodified, explicitly safe view controls stay live. Every
            // other key passes through to AppKit, including VoiceOver chords
            // and unsupported Command combinations.
            guard context.acceptsReviewShortcuts else { return false }
            if event.keyCode == 48 {
                guard context.acceptsNavigationShortcuts,
                      acceptsNavigationModifiers else { return false }
                store.toggleViewMode()
                return true
            }
            guard acceptsReviewModifiers else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q": withAnimation { store.toggleBrowser() }; return true
            case "w": withAnimation { store.showMetadataPanel.toggle() }; return true
            case "x": return store.toggleClippingWarnings()
            case "g": store.toggleViewMode(); return true
            default: return false
            }
        }

        // App commands remain available when a Button, Picker, or Slider has
        // keyboard focus. A live text editor keeps every standard macOS
        // command instead (notably Undo, Select All, and Use Selection for
        // Find).
        let acceptsAppCommand = context.acceptsReviewShortcuts

        // ⌘+ / ⌘− resize the Grid view.
        if acceptsAppCommand,
           modifiers == [.command],
           store.viewMode == .grid {
            switch event.charactersIgnoringModifiers {
            case "=", "+": store.zoomGrid(larger: true); return true
            case "-": store.zoomGrid(larger: false); return true
            default: break
            }
        }
        if acceptsAppCommand,
           modifiers == [.command, .shift],
           store.viewMode == .grid,
           event.characters == "+" {
            store.zoomGrid(larger: true)
            return true
        }

        // These menu-equivalent actions stay here rather than on global menu
        // key equivalents so another window or a focused editor owns its keys.
        if acceptsAppCommand, modifiers == [.command] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "e":
                guard store.canExport else { return false }
                store.presentExport()
                return true
            case "r":
                store.rescan()
                return true
            default:
                break
            }
        }

        // ⌘Z — undo the last rating (or a whole "clear all" / clean-up).
        if acceptsAppCommand,
           modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            store.undo()
            return true
        }

        // ⌘⌫ — move the selected photo(s) straight to the Trash, no dialog
        // (deliberate Finder parallel; ⌘Z brings everything back).
        if context.acceptsReviewShortcuts,
           modifiers == [.command],
           event.keyCode == 51 {
            guard store.canCleanUp,
                  store.hasCleanUpTargets(for: .selection) else {
                return false
            }
            store.performCleanUp(.selection)
            return true
        }

        // ⌘⇧← / ⌘⇧→ — select everything up to the first / last photo.
        if context.acceptsNavigationShortcuts,
           modifiers == [.command, .shift] {
            switch event.keyCode {
            case 123: store.selectToEdge(forward: false); return true   // ⌘⇧←
            case 124: store.selectToEdge(forward: true); return true    // ⌘⇧→
            default: break
            }
        }

        // ⌘A — select all photos that pass the filter.
        if acceptsAppCommand,
           modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            store.selectAllVisible()
            return true
        }

        guard context.acceptsReviewShortcuts else { return false }
        switch event.keyCode {
        case 123:
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            store.goPrevious()
            return true                                      // ←
        case 124:
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            store.goNext()
            return true                                      // →
        case 126:                                             // ↑
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            // Grid: same column, one row up. Gallery: previous photo, matching
            // the vertical Browser strip where the photo above is the previous one.
            if store.viewMode == .grid {
                store.goVertical(-1)
            } else {
                store.goPrevious()
            }
            return true
        case 125:                                             // ↓
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            if store.viewMode == .grid {
                store.goVertical(1)
            } else {
                store.goNext()
            }
            return true
        case 48:
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            store.toggleViewMode()
            return true                                      // Tab
        case 49:                                             // Space
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            if let item = store.currentItem, item.isVideo {
                store.videoPlayback.toggle(item)
            } else {
                store.goNext()
            }
            return true
        case 53:                                             // Esc: drop the selection
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            guard !store.selectedIndices.isEmpty else { return false }
            store.clearSelection()
            return true
        default: break
        }

        // The remaining shortcuts are letters. Shift and ordinary Caps Lock
        // may change their glyph but not their Louppe meaning; every other
        // modifier, including Fn/Globe and Help, remains native.
        guard acceptsReviewModifiers else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": store.rate(.yes); return true
        case "d": store.rate(.no); return true
        case "q": withAnimation { store.toggleBrowser() }; return true
        case "w": withAnimation { store.showMetadataPanel.toggle() }; return true
        case "x": return store.toggleClippingWarnings()
        case "g": store.toggleViewMode(); return true
        case "e":
            guard store.canExport else { return false }
            store.presentExport()
            return true
        case "r": store.requestClearAllRatings(); return true
        case "z": store.undo(); return true                  // bare Z = ⌘Z
        case "s":
            if store.viewMode == .gallery {
                store.toggleZoom(.actual)
                return true
            }
            return false
        case "a":
            if store.viewMode == .gallery {
                store.toggleZoom(.small)
                return true
            }
            return false
        default:
            return false
        }
    }

    private func normalizedShortcutModifiers(
        for event: NSEvent
    ) -> NSEvent.ModifierFlags {
        // Compare only documented, device-independent modifier meanings. Raw
        // event flags can contain unrelated bits, while AppKit marks ordinary
        // arrow-key events as both Numeric Pad and Function.
        let meaningfulMask: NSEvent.ModifierFlags = [
            .capsLock,
            .shift,
            .control,
            .option,
            .command,
            .numericPad,
            .help,
            .function,
        ]
        var modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(meaningfulMask)
        if 123...126 ~= event.keyCode {
            modifiers.subtract([.numericPad, .function])
        }
        return modifiers
    }

    private func liveKeyRoutingContext(
        for event: NSEvent
    ) -> SessionKeyRoutingContext {
#if DEBUG
        let keyWindow =
            SessionKeyMonitorTestProbe.keyWindowOverride ?? NSApp.keyWindow
#else
        let keyWindow = NSApp.keyWindow
#endif
        return SessionKeyRoutingContext(
            eventWindow: event.window,
            eventWindowNumber: event.windowNumber,
            sessionWindow: sessionWindowReference.window,
            keyWindow: keyWindow,
            modalWindow: NSApp.modalWindow
        )
    }

}

/// Inputs that must be true before a session-wide keyboard shortcut is even
/// interpreted. Keeping this value pure makes the dangerous boundary directly
/// regression-testable without synthesizing system-wide accessibility events.
struct SessionKeyRoutingContext: Equatable {
    let sessionOwnsEvent: Bool
    let hasModalPresentation: Bool
    let focusedResponderOwnsText: Bool
    let focusedResponderOwnsNavigation: Bool
    let isVoiceOverEnabled: Bool

    init(
        sessionOwnsEvent: Bool,
        hasModalPresentation: Bool,
        focusedResponderOwnsText: Bool = false,
        focusedResponderOwnsNavigation: Bool = false,
        isVoiceOverEnabled: Bool = false
    ) {
        self.sessionOwnsEvent = sessionOwnsEvent
        self.hasModalPresentation = hasModalPresentation
        self.focusedResponderOwnsText = focusedResponderOwnsText
        self.focusedResponderOwnsNavigation =
            focusedResponderOwnsNavigation
        self.isVoiceOverEnabled = isVoiceOverEnabled
    }

    var acceptsReviewShortcuts: Bool {
        sessionOwnsEvent
            && !hasModalPresentation
            && !focusedResponderOwnsText
    }

    var acceptsNavigationShortcuts: Bool {
        acceptsReviewShortcuts && !focusedResponderOwnsNavigation
    }

    static let focusedSession = SessionKeyRoutingContext(
        sessionOwnsEvent: true,
        hasModalPresentation: false,
        focusedResponderOwnsText: false,
        focusedResponderOwnsNavigation: false,
        isVoiceOverEnabled: false
    )

    static let blocked = SessionKeyRoutingContext(
        sessionOwnsEvent: false,
        hasModalPresentation: false,
        focusedResponderOwnsText: false,
        focusedResponderOwnsNavigation: false,
        isVoiceOverEnabled: false
    )

    @MainActor
    init(
        eventWindow: NSWindow?,
        eventWindowNumber: Int,
        sessionWindow: NSWindow?,
        keyWindow: NSWindow?,
        modalWindow: NSWindow?
    ) {
        guard let sessionWindow else {
            self = .blocked
            return
        }

        let eventBelongsToSession =
            eventWindow === sessionWindow
            || (
                eventWindow == nil
                    && eventWindowNumber != 0
                    && eventWindowNumber == sessionWindow.windowNumber
            )
        let firstResponder = sessionWindow.firstResponder
        self.init(
            sessionOwnsEvent:
                eventBelongsToSession && keyWindow === sessionWindow,
            hasModalPresentation:
                modalWindow != nil || sessionWindow.attachedSheet != nil,
            focusedResponderOwnsText:
                Self.responderOwnsText(firstResponder),
            focusedResponderOwnsNavigation:
                Self.responderOwnsNavigation(firstResponder),
            isVoiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled
        )
    }

    @MainActor
    static func responderOwnsText(
        _ responder: NSResponder?
    ) -> Bool {
        if responder is NSTextView { return true }
        if let control = responder as? NSControl {
            if control.currentEditor() != nil { return true }
            if let field = control as? NSTextField {
                return field.isEditable || field.isSelectable
            }
        }
        guard let view = responder as? NSView else { return false }
        return viewContainsTextOwner(view)
    }

    @MainActor
    static func responderOwnsNavigation(
        _ responder: NSResponder?
    ) -> Bool {
        guard let responder else { return false }
        return !(responder is NSWindow)
    }

    /// SwiftUI selectable `Text` keeps a private hosting proxy first
    /// responder while its public `NSTextField` selection surface is nested
    /// below it. Inspecting public descendant types avoids depending on that
    /// private proxy's class name while preserving native Copy/Select All,
    /// Find-selection, Undo, and deletion commands.
    @MainActor
    private static func viewContainsTextOwner(_ view: NSView) -> Bool {
        if let textView = view as? NSTextView,
           textView.isEditable || textView.isSelectable {
            return true
        }
        if let textField = view as? NSTextField,
           textField.isEditable || textField.isSelectable {
            return true
        }
        return view.subviews.contains(where: viewContainsTextOwner)
    }
}

#if DEBUG
/// Debug-only lifecycle accounting for the in-process event-monitor regression
/// test. Release builds carry no counter or synchronization work.
@MainActor
enum SessionKeyMonitorTestProbe {
    private(set) static var activeMonitorCount = 0
    private(set) static var keyWindowOverride: NSWindow?

    static func didInstall() {
        activeMonitorCount += 1
    }

    static func didRemove() {
        precondition(activeMonitorCount > 0)
        activeMonitorCount -= 1
    }

    static func overrideKeyWindow(with window: NSWindow?) {
        keyWindowOverride = window
    }
}
#endif

/// An inert AppKit marker that lets hosted-view tests distinguish Gallery,
/// Grid, and the shared Info panel without relying on implementation details
/// such as how many ScrollViews SwiftUI happens to create. It is excluded from
/// accessibility and pointer hit testing; the identifier is available to UI
/// diagnostics without changing the rendered app.
struct SessionRenderMarker: NSViewRepresentable {
    enum Kind: String {
        case gallery = "com.alexandermarkin.louppe.render.gallery"
        case grid = "com.alexandermarkin.louppe.render.grid"
        case metadata = "com.alexandermarkin.louppe.render.metadata"
    }

    let kind: Kind

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(kind: kind)
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {
        nsView.kind = kind
    }

    final class MarkerView: NSView {
        var kind: Kind {
            didSet { setAccessibilityIdentifier(kind.rawValue) }
        }

        init(kind: Kind) {
            self.kind = kind
            super.init(frame: .zero)
            setAccessibilityElement(false)
            setAccessibilityIdentifier(kind.rawValue)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// Resolves the exact NSWindow that hosts this SessionView. The event monitor
/// keeps only a weak reference, so it cannot extend the window's lifetime.
private struct SessionWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onWindowChange = onWindowChange
        nsView.reportWindowIfNeeded()
    }

    final class WindowReaderView: NSView {
        var onWindowChange: (NSWindow?) -> Void = { _ in }
        private weak var reportedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindowIfNeeded()
        }

        func reportWindowIfNeeded() {
            guard reportedWindow !== window else { return }
            reportedWindow = window
            onWindowChange(window)
        }
    }
}

private final class SessionWindowReference {
    weak var window: NSWindow?
}

/// The Clean Up menu body — the three trash actions plus the inline scope —
/// shared by the toolbar menu and the File menu so the two never drift.
struct CleanUpMenuItems: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Button(store.selectionCleanUpTitle) {
            store.requestCleanUp(.selection)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .selection))
        Divider()
        Picker("For “No” / “Yes” Actions", selection: $store.cleanUpScope) {
            cleanUpScopeLabel("All Photos", scope: .all)
                .tag(CleanUpScope.all)
            cleanUpScopeLabel("Filtered", scope: .filtered)
                .tag(CleanUpScope.filtered)
            cleanUpScopeLabel("Selected", scope: .selected)
                .tag(CleanUpScope.selected)
        }
        .pickerStyle(.inline)
        .disabled(store.isNewFileOperationBlocked)
        Divider()
        Button("Move “No” to Trash…") {
            store.requestCleanUp(.trashNo)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .trashNo))
        Button("Keep Only “Yes”…") {
            store.requestCleanUp(.keepOnlyYes)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .keepOnlyYes))
    }

    private func cleanUpScopeLabel(_ title: String, scope: CleanUpScope) -> Text {
        Text("\(title) (\(store.cleanUpScopeCount(for: scope)))")
    }
}
