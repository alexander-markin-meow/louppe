import SwiftUI
import AppKit

extension Color {
    /// The single background gray used everywhere in the app (Browser, photo
    /// pane, info panel, Grid view) so there's one consistent shade.
    static let appBackground = Color(nsColor: .windowBackgroundColor)

    /// Louppe's brand purple (#9853A6). The one accent color for everything
    /// that isn't a yes/no rating (those stay green/red): selection borders,
    /// the export button, links, toggles, and the app-icon glyph.
    static let louppeAccent = Color(red: 0x98 / 255, green: 0x53 / 255, blue: 0xA6 / 255)
}

/// Top-level switch between the three app phases:
/// welcome screen → scanning progress → the culling session.
struct RootView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Group {
            switch store.phase {
            case .welcome:
                WelcomeView(store: store)
            case .scanning(let found):
                ScanningView(store: store, found: found)
            case .ready:
                SessionView(store: store)
            }
        }
        // Tint every standard control (buttons, links, pickers, toggles,
        // progress bars — including sheets and popovers) with the brand purple.
        .tint(Color.louppeAccent)
        .frame(minWidth: 900, minHeight: 600)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if store.recoveryNeedsAttention {
                    RecoveryWarningBanner(
                        retry: store.retryInterruptedOperationRecovery
                    )
                }
                if let warning = store.persistenceWarning {
                    PersistenceWarningBanner(
                        message: warning,
                        retry: store.retryPersistence
                    )
                }
            }
        }
        .overlay {
            if store.isRecoveringInterruptedOperations {
                InterruptedOperationRecoveryOverlay()
            }
        }
        .alert(
            recoveryTitle,
            isPresented: operationRecoveryReportIsPresented
        ) {
            if store.operationRecoveryReport?.hasUnresolvedFiles == true {
                Button("Retry Recovery") {
                    store.retryInterruptedOperationRecovery()
                }
                Button("Leave Files Untouched", role: .cancel) {
                    store.dismissOperationRecoveryReport()
                }
            } else {
                Button("OK") {
                    store.dismissOperationRecoveryReport()
                }
            }
        } message: {
            Text(recoveryMessage)
        }
        // The same NSWindow survives all three phases. Welcome/Scanning use
        // full-size content; only the active session opts out so photos cannot
        // scroll behind the glass toolbar. This controls layout, not rounding.
        .background(WindowContentLayout(fullSizeContent: usesFullSizeWindowContent))
    }

    private var usesFullSizeWindowContent: Bool {
        switch store.phase {
        case .welcome, .scanning:
            return true
        case .ready:
            return false
        }
    }

    private var operationRecoveryReportIsPresented: Binding<Bool> {
        Binding(
            get: { store.operationRecoveryReport != nil },
            set: {
                if !$0 { store.dismissOperationRecoveryReport() }
            }
        )
    }

    private var recoveryTitle: String {
        store.operationRecoveryReport?.hasUnresolvedFiles == true
            ? "Some files need attention"
            : "Interrupted operation recovered"
    }

    private var recoveryMessage: String {
        guard let report = store.operationRecoveryReport else { return "" }
        if report.hasUnresolvedFiles {
            var message = "Louppe recovered everything it could, but left "
                + "\(report.unresolvedFiles) file"
                + (report.unresolvedFiles == 1 ? "" : "s")
                + " untouched because it couldn't confirm the exact file or volume. "
                + "Reconnect any drive used by the operation, then retry."
            if let detail = report.details.first {
                message += " \(detail)"
            }
            return message
        }

        var actions: [String] = []
        if report.restoredFiles > 0 {
            actions.append(
                "restored \(report.restoredFiles) original file"
                    + (report.restoredFiles == 1 ? "" : "s")
            )
        }
        if report.removedPartialCopies > 0 {
            actions.append(
                "removed \(report.removedPartialCopies) incomplete cop"
                    + (report.removedPartialCopies == 1 ? "y" : "ies")
            )
        }
        if actions.isEmpty {
            return "Louppe verified the completed operation and cleared its recovery record. No photo or video was changed."
        }
        return "Louppe \(actions.joined(separator: " and ")). No existing file was overwritten."
    }
}

private struct InterruptedOperationRecoveryOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Making interrupted file operations safe…")
                .font(.headline)
            Text("Louppe is checking exact file identities before opening a folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
    }
}

private struct RecoveryWarningBanner: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Some interrupted files are still untouched. Reconnect the drive used by the operation, then retry recovery.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Retry Recovery", action: retry)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Visible but non-modal: review can continue while a read-only folder uses
/// the backup, and an unsafe save can be retried without dismissing an alert.
private struct PersistenceWarningBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Session save warning. \(message)")
            Spacer(minLength: 12)
            Button("Retry Saving", action: retry)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Keeps the persistent app window's content layout in sync with the current
/// SwiftUI phase. Window corner geometry remains entirely system-owned.
private struct WindowContentLayout: NSViewRepresentable {
    let fullSizeContent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = Configurator()
        view.fullSizeContent = fullSizeContent
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? Configurator else { return }
        view.fullSizeContent = fullSizeContent
        view.apply()
    }

    private final class Configurator: NSView {
        var fullSizeContent = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            guard window.styleMask.contains(.fullSizeContentView) != fullSizeContent else { return }
            if fullSizeContent {
                window.styleMask.insert(.fullSizeContentView)
            } else {
                window.styleMask.remove(.fullSizeContentView)
            }
        }
    }
}
