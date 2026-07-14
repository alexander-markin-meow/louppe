import SwiftUI

/// The Louppe logo — the same 3×3 grid as the app icon, with the middle
/// "keeper" tile filled — drawn natively so it stays crisp at any size and
/// always matches the brand purple. Proportions were measured from the
/// 1024 px app-icon master (AppIcon/AppIcon-1024.png).
struct LouppeLogo: View {
    var size: CGFloat = 64

    var body: some View {
        let tile = size / 3.82          // 3 tiles + 2 gaps of 0.41 × tile
        let gap = tile * 0.41
        let stroke = tile * 0.135
        let radius = tile * 0.2
        VStack(spacing: gap) {
            ForEach(0..<3) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3) { column in
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(Color.louppeAccent, lineWidth: stroke)
                            .background(
                                // Only the center tile — the keeper — is filled.
                                row == 1 && column == 1
                                    ? RoundedRectangle(cornerRadius: radius).fill(Color.louppeAccent)
                                    : nil
                            )
                            .frame(width: tile, height: tile)
                    }
                }
            }
        }
    }
}

/// The start screen: pick a folder (or a recent one) to begin a session.
struct WelcomeView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 18) {
            LouppeLogo(size: 64)
            Text("Louppe")
                .font(.largeTitle.bold())
                .foregroundStyle(Color.louppeAccent)
            Text("Pick a folder of photos, mark each one Yes or No,\nthen export the keepers. Originals are never changed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                store.promptForSourceFolder()
            } label: {
                Label("Choose Photo Folder…", systemImage: "folder")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .keyboardShortcut("o")

            if let error = store.scanError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if !store.recentFolders.isEmpty {
                VStack(spacing: 6) {
                    Text("Recent")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    ForEach(store.recentFolders.prefix(5), id: \.path) { url in
                        Button {
                            store.openFolder(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "clock")
                                .frame(maxWidth: 320)
                        }
                        .buttonStyle(.link)
                        .help(url.path)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .toolbar { LaunchToolbarTitle() }
        .navigationTitle("")
    }
}

/// Shown while a folder scan is in progress.
struct ScanningView: View {
    let found: Int

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(found > 0 ? "Scanning… \(found) photos found" : "Scanning folder…")
                .foregroundStyle(.secondary)
        }
        .toolbar { LaunchToolbarTitle() }
        .navigationTitle("")
    }
}

/// Welcome and Scanning deliberately use a real unified toolbar rather than a
/// custom rounded window. On macOS 26 this gives the launch window Apple's
/// larger native toolbar-window corners while preserving the centered title.
private struct LaunchToolbarTitle: ToolbarContent {
    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                Text("Louppe")
                    .font(.headline)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                Text("Louppe")
                    .font(.headline)
            }
        }
    }
}
