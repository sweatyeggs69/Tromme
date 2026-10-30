import Foundation
import Observation

@MainActor
@Observable
final class BlockedLyricsStore {
    static let shared = BlockedLyricsStore()

    private struct Block: Codable, Equatable {
        let fingerprint: String
        let textFingerprint: String
    }

    private var blocked: [String: [Block]]

    private let fileURL: URL

    private init() {
        let dir = URL.applicationSupportDirectory.appending(path: "TrommeLyrics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "blockedLyrics-v2.json")
        try? FileManager.default.removeItem(at: dir.appending(path: "blockedLyrics.json"))
        blocked = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: [Block]].self, from: $0) } ?? [:]
    }

    static func songKey(title: String, artist: String) -> String {
        "\(artist.lowercased())\u{1F}\(title.lowercased())"
    }

    func fingerprints(forSong key: String) -> Set<String> {
        Set((blocked[key] ?? []).flatMap { [$0.fingerprint, $0.textFingerprint] })
    }

    func blockCount(forSong key: String) -> Int {
        blocked[key]?.count ?? 0
    }

    func block(_ lyrics: ResolvedLyrics, forSong key: String) {
        guard let fingerprint = lyrics.fingerprint, let textFingerprint = lyrics.textFingerprint else { return }
        let block = Block(fingerprint: fingerprint, textFingerprint: textFingerprint)
        var list = blocked[key] ?? []
        guard !list.contains(block) else { return }
        list.append(block)
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
