import SwiftUI

/// The start screen: pick a folder (or a recent one) to begin a session.
struct WelcomeView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Louppe")
                .font(.largeTitle.bold())
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
    }
}
