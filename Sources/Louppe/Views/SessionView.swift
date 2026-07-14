import SwiftUI
import AppKit

/// The active culling session: hosts the culling/light-table views, the
/// toolbar, the export sheet, and all single-key hotkeys.
///
/// Hotkey map (README's table must stay in sync with `handleKey`):
///   F yes · D no · S 100% zoom · A phone-size zoom · R clear all
///   Q browser · W info panel · E export · Space next · ←/→ prev/next
///   Tab/G switch view · Z/⌘Z undo · ⌘+/⌘− grid size
///   ⌘A select all · ⌘⇧←/→ select to first/last · Esc clear selection
///   ⌘⌫ trash selection (no confirmation — ⌘Z restores)
///   (⇧-click range and ⌘-click add/remove live in the thumbnail views)
struct SessionView: View {
    @ObservedObject var store: SessionStore
    @State private var keyMonitor: Any?

    var body: some View {
        mainContent
            .toolbar { toolbarContent }
            .navigationTitle("")
            // Keep the native liquid-glass toolbar, but lay the window content
            // out *below* it instead of extending underneath — so thumbnails and
            // the info panel can never scroll up behind the toolbar.
            .background(BelowToolbarLayout())
            .sheet(isPresented: $store.isExportPresented) {
                ExportView(store: store)
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

    private var isCleanUpConfirmPresented: Binding<Bool> {
        Binding(
            get: { store.pendingCleanUp != nil },
            set: { if !$0 { store.pendingCleanUp = nil } }
        )
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
            return "Move \(photosPhrase(counts.photos)) to the Trash?"
        case .trashNo:
            return "Move \(photosPhrase(counts.photos)) marked “No” to the Trash?"
        case .keepOnlyYes:
            return "Move \(photosPhrase(counts.photos)) not marked “Yes” to the Trash?"
        }
    }

    private func cleanUpMessage(for mode: CleanUpMode) -> String {
        let counts = store.cleanUpCounts(for: mode)
        let files = counts.files == 1 ? "1 file" : "\(counts.files) files"
        var parts = ["\(files) will move to the macOS Trash (a RAW+JPEG pair counts as two)."]
        switch mode {
        case .selection:
            parts.append("Only the selected photos leave the folder; everything else stays.")
        case .trashNo:
            parts.append("Photos marked “Yes” and unrated photos stay in the folder.")
        case .keepOnlyYes:
            parts.append("Every photo not marked “Yes” — including unrated ones — leaves the folder.")
        }
        // With a filter active, spell out the scope of the rating-based
        // options so nothing hidden is trashed (or spared) by surprise.
        // (A selection is already explicit — no scope to explain.)
        if mode != .selection {
            if store.cleanUpScopeIsFiltered {
                let hidden = store.items.count - store.visibleIndices.count
                parts.append("Only the \(store.visibleIndices.count) photos the filter shows are considered — the \(hidden) hidden ones aren't touched.")
            } else if store.filter.isActive {
                parts.append("All \(store.items.count) photos in the folder are considered, including the ones the filter currently hides.")
            }
        }
        parts.append("Nothing is deleted permanently: press ⌘Z to put everything back.")
        return parts.joined(separator: " ")
    }

    private func photosPhrase(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }

    private var subtitle: String {
        guard !store.items.isEmpty else { return "" }
        let position = (store.visibleIndices.firstIndex(of: store.currentIndex) ?? 0) + 1
        var text = "\(position) of \(store.visibleIndices.count)"
        if store.filter.isActive {
            text += " (of \(store.items.count) total)"
        }
        text += "  ·  ✓ \(store.yesCount)  ✗ \(store.noCount)  · \(store.undecidedCount) left"
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
            // Photo-decode spinner. Always present (just invisible when idle)
            // so the status text doesn't shift when it appears.
            ProgressView()
                .controlSize(.small)
                .opacity(store.fullImageLoads > 0 ? 1 : 0)
        }
    }

    private var mainContent: some View {
        Group {
            switch store.viewMode {
            case .culling:
                CullingView(store: store)
            case .lightTable:
                LightTableView(store: store)
            }
        }
    }

    // MARK: - Toolbar

    /// Toolbar order (rearranged 2026-07-13 per the owner):
    /// folder · re-scan · filter · sort · view picker = status =
    /// undo · clear all · clean up · browser · info · export.
    /// Capsule grouping on BOTH sides is deliberately left to macOS
    /// (spacer-based regrouping was tried twice and reverted: .navigation
    /// ignores spacers, and on the trailing side the owner preferred the
    /// automatic look).
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Current folder: a real button — click it to go back to the start
        // screen and pick a different folder (the session is saved first).
        ToolbarItem(placement: .navigation) {
            Button {
                store.closeSession()
            } label: {
                Label(store.sourceFolder?.lastPathComponent ?? "Folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .help("Choose another folder")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                store.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-scan for new photos (⌘R)")
        }

        filterItem
        sortItem

        // The view switcher lives on the left, next to what it switches.
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $store.viewMode) {
                Image(systemName: "photo").tag(ViewMode.culling)
                Image(systemName: "square.grid.3x3").tag(ViewMode.lightTable)
            }
            .pickerStyle(.segmented)
            .help("Switch view (Tab)")
        }

        // Session status, centered in the toolbar at the same height as the
        // other toolbar controls — plain text, opted out of the glass capsule.
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

        trailingItems
    }

    /// Filter: opens the glass popover with search / date / type filters.
    @ToolbarContentBuilder
    private var filterItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
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
            .help("Filter the photos")
        }
    }

    /// Sort: a native menu with check-marked pickers, like Finder's
    /// sort menu. Only reorders what's shown — never touches ratings.
    @ToolbarContentBuilder
    private var sortItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Sort by", selection: $store.sort.key) {
                    Text("Date taken").tag(PhotoSort.Key.captureDate)
                    Text("Name").tag(PhotoSort.Key.name)
                }
                Divider()
                Picker("Order", selection: $store.sort.ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .pickerStyle(.inline)
            .menuIndicator(.hidden)
            // Keep the glyph neutral — menus inherit the purple accent.
            .tint(Color.primary)
            .help("Sort the photos")
        }
    }

    /// One flat group — the capsule layout is deliberately left to macOS
    /// (explicit ToolbarSpacer splits were tried on 2026-07-13 and the owner
    /// preferred the system's automatic grouping).
    @ToolbarContentBuilder
    private var trailingItems: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            .help("Undo (Z)")
            Button {
                store.clearAllRatings()
            } label: {
                Image(systemName: "eraser")
            }
            .help("Clear all ratings (R)")

            // Clean up: the one place the app touches originals — and only
            // ever by moving them to the macOS Trash, behind a confirmation.
            // The menu body is shared with the File menu (CleanUpMenuItems).
            Menu {
                CleanUpMenuItems(store: store)
            } label: {
                Image(systemName: "trash")
            }
            .menuIndicator(.hidden)
            // Menus pick up the global purple accent; retint just this one
            // so the glyph stays neutral like its button neighbours.
            // (foregroundStyle on the label image doesn't stick — toolbar
            // menus take their colour from tint.)
            .tint(Color.primary)
            .help("Clean up: move photos to the Trash")

            Button {
                withAnimation { store.showFilmstrip.toggle() }
            } label: {
                Image(systemName: store.showFilmstrip ? "sidebar.squares.left" : "sidebar.left")
            }
            .help("Show/hide the browser (Q)")

            Button {
                withAnimation { store.showMetadataPanel.toggle() }
            } label: {
                Image(systemName: "info.circle")
            }
            .help("Show/hide photo info (W)")
        }

        // Export: its own prominent purple button. Use a bare Image (not a
        // Label with hidden text) so the icon centers in the circle instead
        // of being nudged aside by reserved label space.
        ToolbarItem {
            Button {
                store.isExportPresented = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    // Nudge up a touch to visually center the share glyph.
                    .offset(y: -1)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(Color.louppeAccent)
            .help("Export the “Yes” photos (E)")
        }
    }

    // MARK: - Keyboard shortcuts

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handleKey(event) { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // Leave command shortcuts (⌘Z, ⌘E…) to the menu bar, and don't steal
        // keys while the export sheet or a panel is up or the user is typing.
        guard case .ready = store.phase else { return false }
        if store.isExportPresented { return false }
        // Don't steal letters while the filter popover is up (search typing).
        if store.isFilterPresented { return false }
        // Nor while the clean-up confirmation or its error alert is up.
        if store.pendingCleanUp != nil || store.cleanUpError != nil { return false }

        // ⌘+ / ⌘− resize the light table grid.
        if event.modifierFlags.contains(.command), store.viewMode == .lightTable {
            switch event.charactersIgnoringModifiers {
            case "=", "+": store.zoomGrid(larger: true); return true
            case "-": store.zoomGrid(larger: false); return true
            default: break
            }
        }

        // ⌘Z — undo the last rating (or a whole "clear all" / clean-up).
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            store.undo()
            return true
        }

        // ⌘⌫ — move the selected photo(s) straight to the Trash, no dialog
        // (deliberate Finder parallel; ⌘Z brings everything back).
        if event.modifierFlags.contains(.command), event.keyCode == 51 {
            store.performCleanUp(.selection)
            return true
        }

        // ⌘⇧← / ⌘⇧→ — select everything up to the first / last photo.
        if event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift) {
            switch event.keyCode {
            case 123: store.selectToEdge(forward: false); return true   // ⌘⇧←
            case 124: store.selectToEdge(forward: true); return true    // ⌘⇧→
            default: break
            }
        }

        // ⌘A — select all photos that pass the filter.
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            store.selectAllVisible()
            return true
        }

        if event.modifierFlags.intersection([.command, .option, .control]) != [] { return false }
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }

        switch event.keyCode {
        case 123: store.goPrevious(); return true            // ←
        case 124: store.goNext(); return true                // →
        case 48:  store.toggleViewMode(); return true        // Tab
        case 49:  store.goNext(); return true                // Space: next, no rating
        case 53:                                             // Esc: drop the selection
            guard !store.selectedIndices.isEmpty else { return false }
            store.clearSelection()
            return true
        default: break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": store.rate(.yes); return true
        case "d": store.rate(.no); return true
        case "q": withAnimation { store.showFilmstrip.toggle() }; return true
        case "w": withAnimation { store.showMetadataPanel.toggle() }; return true
        case "g": store.toggleViewMode(); return true
        case "e": store.isExportPresented = true; return true
        case "r": store.clearAllRatings(); return true
        case "z": store.undo(); return true                  // bare Z = ⌘Z
        case "s":
            if store.viewMode == .culling {
                store.toggleZoom(.actual)
                return true
            }
            return false
        case "a":
            if store.viewMode == .culling {
                store.toggleZoom(.small)
                return true
            }
            return false
        default:
            return false
        }
    }
}

/// The Clean Up menu body — the three trash actions plus the scope toggle —
/// shared by the toolbar menu and the File menu so the two never drift.
struct CleanUpMenuItems: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Button(store.selectionCleanUpTitle) {
            store.pendingCleanUp = .selection
        }
        .disabled(!store.hasCleanUpTargets(for: .selection))
        Divider()
        Button("Move “No” to Trash…") {
            store.pendingCleanUp = .trashNo
        }
        .disabled(!store.hasCleanUpTargets(for: .trashNo))
        Button("Keep Only “Yes”…") {
            store.pendingCleanUp = .keepOnlyYes
        }
        .disabled(!store.hasCleanUpTargets(for: .keepOnlyYes))
        // Scope toggle — only meaningful while a filter is active (without
        // one, "filtered" and "everything" are the same set).
        if store.filter.isActive {
            Divider()
            Toggle("Limit to Filtered Photos", isOn: $store.cleanUpFilteredOnly)
        }
    }
}

/// Removes the window's "full-size content" flag so the content area starts
/// below the toolbar rather than extending under it. The toolbar itself keeps
/// its standard translucent glass appearance.
struct BelowToolbarLayout: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Configurator() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Configurator: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.styleMask.remove(.fullSizeContentView)
        }
    }
}
