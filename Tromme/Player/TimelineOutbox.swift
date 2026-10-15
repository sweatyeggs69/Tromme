import Foundation

/// Finished plays whose `stopped` timeline couldn't reach the server (offline listening,
/// server briefly unreachable). Persisted to disk and replayed once the server is
/// reachable again with the spec's `offline` and `updated` timeline parameters, so
/// play history doesn't silently drop offline plays.
actor TimelineOutbox {
    static let shared = TimelineOutbox()

    private struct Entry: Codable, Equatable {
        let ratingKey: String
        let key: String
        let timeMs: Int
        let durationMs: Int
        /// Unix time the play finished.
        let updated: Int
        let machineIdentifier: String
    }

    private static let maxEntries = 500

    private let fileURL: URL
    private var entries: [Entry]
    private var isFlushing = false

    private init() {
        let dir = URL.applicationSupportDirectory.appending(path: "TrommePlaybackState", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "timelineOutbox.json")
        entries = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        // Replaces the scrobble outbox from an earlier build; its entries can't be replayed as timelines.
        try? FileManager.default.removeItem(at: dir.appending(path: "scrobbleOutbox.json"))
    }

    func enqueue(ratingKey: String, key: String, timeMs: Int, durationMs: Int, server: PlexServer) {
        entries.append(Entry(
            ratingKey: ratingKey,
            key: key,
            timeMs: timeMs,
            durationMs: durationMs,
            updated: Int(Date().timeIntervalSince1970),
            machineIdentifier: server.machineIdentifier
        ))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        persist()
    }

    /// Sends queued timelines for `server`, stopping at the first failure (still offline).
    func flush(server: PlexServer, client: PlexAPIClient) async {
        guard !isFlushing, entries.contains(where: { $0.machineIdentifier == server.machineIdentifier }) else { return }
        isFlushing = true
        defer { isFlushing = false }
        for entry in entries where entry.machineIdentifier == server.machineIdentifier {
            do {
                try await client.reportTimeline(
                    server: server,
                    ratingKey: entry.ratingKey,
                    key: entry.key,
                    state: "stopped",
                    timeMs: entry.timeMs,
                    durationMs: entry.durationMs,
                    sessionID: nil,
                    offline: true,
                    updated: entry.updated
                )
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
