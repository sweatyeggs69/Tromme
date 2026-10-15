import Foundation
import Observation

/// Lyrics the user marked as wrong or out of sync, per song. Each entry is the
/// fingerprint of a rejected LRC/plain text, so the resolver skips it and falls
/// through to the next match. Persisted as JSON in Application Support.
@MainActor
@Observable
final class BlockedLyricsStore {
    static let shared = BlockedLyricsStore()

    /// Song key (artist + title) to blocked lyrics fingerprints.
    private var blocked: [String: [String]]

    private let fileURL: URL

    private init() {
        let dir = URL.applicationSupportDirectory.appending(path: "TrommeLyrics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "blockedLyrics.json")
        blocked = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    static func songKey(title: String, artist: String) -> String {
        "\(artist.lowercased())\u{1F}\(title.lowercased())"
    }

    func fingerprints(forSong key: String) -> Set<String> {
        Set(blocked[key] ?? [])
    }

    func hasBlocks(forSong key: String) -> Bool {
        blocked[key]?.isEmpty == false
    }

    func block(_ fingerprint: String, forSong key: String) {
        var list = blocked[key] ?? []
        guard !list.contains(fingerprint) else { return }
        list.append(fingerprint)
        blocked[key] = list
        persist()
    }

    func clear(forSong key: String) {
        guard blocked.removeValue(forKey: key) != nil else { return }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(blocked) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
