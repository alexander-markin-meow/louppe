import SwiftUI
import AppKit

/// The active culling session: hosts the culling/light-table views, the
/// toolbar, the export sheet, and all single-key hotkeys.
///
/// Hotkey map (README's table must stay in sync with `handleKey`):
///   F yes · D no · S 100% zoom · A phone-size zoom · R clear all
///   Q browser · W info panel · E export · Space next · ←/→ prev/next
///   Tab/G switch view · ⌘Z undo · ⌘+/⌘− grid size
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
            .onAppear(perform: installKeyMonitor)
            .onDisappear(perform: removeKeyMonitor)
    }

    private var subtitle: String {
        guard !store.items.isEmpty else { return "" }
        let position = (store.visibleIndices.firstIndex(of: store.currentIndex) ?? 0) + 1
        var text = "\(position) of \(store.visibleIndices.count)"
        if store.filter.isActive {
            text += " (of \(store.items.count) total)"
        }
        return text + "  ·  ✓ \(store.yesCount)  ✗ \(store.noCount)  · \(store.undecidedCount) left"
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

    /// Original arrangement: separate navigation items in order
    /// folder / filter / sort / re-scan; macOS groups the glass itself.
    /// (ToolbarSpacer-based regrouping was tried and reverted — the
    /// .navigation area ignores spacers on macOS 26.)
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
            .help("Back to the start screen to open another folder")
        }

        filterItem
        sortItem

        ToolbarItem(placement: .navigation) {
            Button {
                store.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-scan this folder for new photos (⌘R)")
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
            .help("Filter which photos are shown")
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
            .help("Sort photos by date taken or name")
        }
    }

    @ToolbarContentBuilder
    private var trailingItems: some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: $store.viewMode) {
                Image(systemName: "photo").tag(ViewMode.culling)
                    .help("Main culling view (Tab)")
                Image(systemName: "square.grid.3x3").tag(ViewMode.lightTable)
                    .help("Light table grid (Tab)")
            }
            .pickerStyle(.segmented)

            Button {
                store.clearAllRatings()
            } label: {
                Image(systemName: "eraser")
            }
            .help("Clear all ratings — undo with ⌘Z (R)")

            Button {
                withAnimation { store.showFilmstrip.toggle() }
            } label: {
                Image(systemName: store.showFilmstrip ? "sidebar.squares.left" : "sidebar.left")
            }
            .help("Show or hide the browser (Q)")

            Button {
                withAnimation { store.showMetadataPanel.toggle() }
            } label: {
                Image(systemName: "info.circle")
            }
            .help("Show or hide photo info (W)")
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
            .help("Export the photos marked Yes (E)")
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

        // ⌘+ / ⌘− resize the light table grid.
        if event.modifierFlags.contains(.command), store.viewMode == .lightTable {
            switch event.charactersIgnoringModifiers {
            case "=", "+": store.zoomGrid(larger: true); return true
            case "-": store.zoomGrid(larger: false); return true
            default: break
            }
        }

        // ⌘Z — undo the last rating (or a whole "clear all").
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            store.undo()
            return true
        }

        if event.modifierFlags.intersection([.command, .option, .control]) != [] { return false }
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }

        switch event.keyCode {
        case 123: store.goPrevious(); return true            // ←
        case 124: store.goNext(); return true                // →
        case 48:  store.toggleViewMode(); return true        // Tab
        case 49:  store.goNext(); return true                // Space: next, no rating
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
