import Foundation

/// Plays that couldn't be reported to the server (offline listening, server briefly
/// unreachable). Persisted to disk and flushed once the server is reachable again, so
/// play counts and Recently Played don't silently drop offline plays.
actor ScrobbleOutbox {
    static let shared = ScrobbleOutbox()

    private struct Entry: Codable, Equatable {
        let ratingKey: String
        let machineIdentifier: String
    }

    private static let maxEntries = 500

    private let fileURL: URL
    private var entries: [Entry]
    private var isFlushing = false

    private init() {
        let dir = URL.applicationSupportDirectory.appending(path: "TrommePlaybackState", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "scrobbleOutbox.json")
        entries = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func enqueue(ratingKey: String, server: PlexServer) {
        entries.append(Entry(ratingKey: ratingKey, machineIdentifier: server.machineIdentifier))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        persist()
    }

    /// Sends queued plays for `server`, stopping at the first failure (still offline).
    func flush(server: PlexServer, client: PlexAPIClient) async {
        guard !isFlushing, entries.contains(where: { $0.machineIdentifier == server.machineIdentifier }) else { return }
        isFlushing = true
        defer { isFlushing = false }
        for entry in entries where entry.machineIdentifier == server.machineIdentifier {
            do {
                try await client.reportScrobble(server: server, ratingKey: entry.ratingKey)
            } catch {
                return
            }
            if let index = entries.firstIndex(of: entry) {
                entries.remove(at: index)
                persist()
            }
        }
    }

    private func persist() {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
