import SwiftUI
import AppKit

/// The active culling session: hosts the Gallery and Grid views, the
/// toolbar, the export sheet, and all single-key hotkeys.
///
/// Hotkey map (README's table must stay in sync with `handleKey`):
///   F yes · D no · S 100% zoom · A phone-size zoom · R clear all
///   Q browser · W info panel · E export · Space next · ←/→ prev/next
///   ↑/↓ same-column photo in the Grid view
///   Tab/G switch view · Z/⌘Z undo · ⌘+/⌘− grid size
///   ⌘A select all · ⌘⇧←/→ select to first/last · Esc clear selection
///   ⌘⌫ trash selection (no confirmation — ⌘Z restores)
///   (⇧-click range and ⌘-click add/remove live in the thumbnail views)
struct SessionView: View {
    @ObservedObject var store: SessionStore
    @State private var keyMonitor: Any?

    var body: some View {
        mainContent
            .overlay { cleanUpProgressOverlay }
            .toolbar { toolbarContent }
            .navigationTitle("")
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
        let space = ByteCountFormatter.string(fromByteCount: counts.bytes, countStyle: .file)
        var parts = ["\(files) will be moved to Trash (RAW+JPEG pair counts as two), freeing \(space) of space."]
        switch mode {
        case .selection:
            parts.append("Only the selected photos will leave the folder; everything else stays.")
        case .trashNo:
            parts.append("Photos marked “Yes” and unrated photos stay in the folder.")
        case .keepOnlyYes:
            parts.append("Only photos marked “Yes” stay in the folder.")
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
        return parts.joined(separator: "\n")
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
        .help("Review progress and rating totals")
    }

    private var mainContent: some View {
        Group {
            switch store.viewMode {
            case .gallery:
                GalleryView(store: store)
            case .grid:
                GridView(store: store)
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

    /// Toolbar order and Liquid Glass groups (2026-07-14):
    /// {folder · re-scan · clean up} {filter · sort · view picker} = status =
    /// {undo · clear all} {browser · info} {export}.
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
            .disabled(store.isCleaningUp)
            .help("Choose another photo folder (⌘O)")

            Button {
                store.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isCleaningUp)
            .help("Re-scan the current folder for new photos (⌘R)")

            // The menu body is shared with the File menu. Clean Up is the
            // only feature that touches originals, and only moves them to
            // the macOS Trash after confirmation.
            Menu {
                CleanUpMenuItems(store: store)
            } label: {
                Image(systemName: "document.on.trash")
                    // Toolbar Menu styling ignores imageScale on macOS 26;
                    // scale the drawing while retaining the normal hit area.
                    .scaleEffect(0.78)
            }
            .disabled(store.isCleaningUp)
            .menuIndicator(.hidden)
            .tint(Color.primary)
            .help("Choose photos to move to the Trash")
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
            .help("Filter photos by metadata, date, type, camera, or lens")

            // A native menu with check-marked pickers, like Finder's sort
            // menu. It only reorders what's shown and never touches ratings.
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
            .help("Sort photos by date or name")

            Picker("View", selection: $store.viewMode) {
                Image(systemName: "photo").tag(ViewMode.gallery)
                Image(systemName: "square.grid.3x3").tag(ViewMode.grid)
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
            .disabled(store.isCleaningUp || !store.canUndo)
            .help("Undo the last rating or clean-up (Z or ⌘Z)")
            Button {
                store.clearAllRatings()
            } label: {
                Image(systemName: "eraser")
            }
            .disabled(store.isCleaningUp)
            .help("Clear all photo ratings (R)")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItemGroup {
            Button {
                withAnimation { store.showBrowser.toggle() }
            } label: {
                Image(systemName: store.showBrowser ? "sidebar.squares.left" : "sidebar.left")
            }
            .help("Show or hide the Browser in the Gallery view (Q)")

            Button {
                withAnimation { store.showMetadataPanel.toggle() }
            } label: {
                Image(systemName: "info.circle")
            }
            .help("Show or hide photo information (W)")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
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
            .disabled(store.isCleaningUp)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(Color.louppeAccent)
            .help("Export copies of the photos marked “Yes” (E or ⌘E)")
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
        if store.isCleaningUp {
            // Command shortcuts continue to the menu bar, whose mutating
            // actions are disabled/guarded. Keep only view controls live.
            if event.modifierFlags.contains(.command) { return false }
            if event.keyCode == 48 { store.toggleViewMode(); return true }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q": withAnimation { store.showBrowser.toggle() }; return true
            case "w": withAnimation { store.showMetadataPanel.toggle() }; return true
            case "g": store.toggleViewMode(); return true
            default: return true
            }
        }
        if store.isExportPresented { return false }
        // Don't steal letters while the filter popover is up (search typing).
        if store.isFilterPresented { return false }
        // Nor while the clean-up confirmation or its error alert is up.
        if store.pendingCleanUp != nil || store.cleanUpError != nil { return false }

        // ⌘+ / ⌘− resize the Grid view.
        if event.modifierFlags.contains(.command), store.viewMode == .grid {
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
        case 126:                                             // ↑
            guard store.viewMode == .grid else { return false }
            store.goVertical(-1)
            return true
        case 125:                                             // ↓
            guard store.viewMode == .grid else { return false }
            store.goVertical(1)
            return true
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
        case "q": withAnimation { store.showBrowser.toggle() }; return true
        case "w": withAnimation { store.showMetadataPanel.toggle() }; return true
        case "g": store.toggleViewMode(); return true
        case "e": store.isExportPresented = true; return true
        case "r": store.clearAllRatings(); return true
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
}

/// The Clean Up menu body — the three trash actions plus the scope toggle —
/// shared by the toolbar menu and the File menu so the two never drift.
struct CleanUpMenuItems: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Button(store.selectionCleanUpTitle) {
            store.requestCleanUp(.selection)
        }
        .disabled(store.isCleaningUp || !store.hasCleanUpTargets(for: .selection))
        Divider()
        Button("Move “No” to Trash…") {
            store.requestCleanUp(.trashNo)
        }
        .disabled(store.isCleaningUp || !store.hasCleanUpTargets(for: .trashNo))
        Button("Keep Only “Yes”…") {
            store.requestCleanUp(.keepOnlyYes)
        }
        .disabled(store.isCleaningUp || !store.hasCleanUpTargets(for: .keepOnlyYes))
        // Scope toggle — only meaningful while a filter is active (without
        // one, "filtered" and "everything" are the same set).
        if store.filter.isActive {
            Divider()
            Toggle("Limit to Filtered Photos", isOn: $store.cleanUpFilteredOnly)
        }
    }
}
