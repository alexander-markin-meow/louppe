import Foundation

/// Serializes sidecar reads and writes away from the main actor.
///
/// Save requests carry a monotonically increasing sequence number. This makes
/// fire-and-forget saves safe: if task scheduling delivers an older snapshot
/// late, it cannot overwrite a newer sidecar for the same folder.
actor SessionPersistence {
    private var latestSequenceByFolder: [String: UInt64] = [:]

    func save(_ session: SessionFile, for folder: URL, sequence: UInt64) {
        let standardizedFolder = folder.standardizedFileURL
        let folderKey = standardizedFolder.path
        guard sequence > latestSequenceByFolder[folderKey, default: 0] else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }

        let sidecar = standardizedFolder.appendingPathComponent(SessionConstants.sidecarName)
        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            do {
                try data.write(to: fallbackSessionURL(for: standardizedFolder), options: .atomic)
            } catch {
                // Do not mark the sequence as persisted. A later request (or
                // an explicit retry of this snapshot) must still be accepted.
                return
            }
        }
        latestSequenceByFolder[folderKey] = sequence
    }

    func read(for folder: URL) -> SessionFile? {
        let standardizedFolder = folder.standardizedFileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = standardizedFolder.appendingPathComponent(SessionConstants.sidecarName)
        if let data = try? Data(contentsOf: sidecar),
           let session = try? decoder.decode(SessionFile.self, from: data) {
            return session
        }
        if let data = try? Data(contentsOf: fallbackSessionURL(for: standardizedFolder)),
           let session = try? decoder.decode(SessionFile.self, from: data) {
            return session
        }
        return nil
    }

    private func fallbackSessionURL(for folder: URL) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Louppe/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var hash: UInt64 = 14695981039346656037
        for byte in folder.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return dir.appendingPathComponent(String(format: "%016llx.json", hash))
    }
}
