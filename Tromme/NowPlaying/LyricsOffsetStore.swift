import Foundation
import Observation

@MainActor
@Observable
final class LyricsOffsetStore {
    static let shared = LyricsOffsetStore()

    static let defaultOffset = 150
    static let step = 50
    static let range = -3000...3000

    private static let cloudKey = "lyricsOffsets"

    private var offsets: [String: Int] = [:]
    private let cloud = NSUbiquitousKeyValueStore.default

    private init() {
        load()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullFromCloud() }
        }
        cloud.synchronize()
        pullFromCloud(merging: true)
        pushToCloud()
    }

    private static func key(for track: PlexMetadata) -> String {
        BlockedLyricsStore.songKey(title: track.title, artist: track.artistDisplayName)
    }

    func offset(for track: PlexMetadata?) -> Int {
        guard let track else { return Self.defaultOffset }
        return offsets[Self.key(for: track)] ?? Self.defaultOffset
    }

    func setOffset(_ value: Int, for track: PlexMetadata) {
        let clamped = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        let key = Self.key(for: track)
        if clamped == Self.defaultOffset {
            guard offsets.removeValue(forKey: key) != nil else { return }
        } else {
            guard offsets[key] != clamped else { return }
            offsets[key] = clamped
        }
        persist()
    }

    // MARK: - Persistence

    private var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "TrommeLyrics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "lyricsOffsets.json")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        try? data.write(to: fileURL, options: .atomic)
        pushToCloud()
    }

    private func pushToCloud() {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        cloud.set(data, forKey: Self.cloudKey)
        cloud.synchronize()
    }

    private func pullFromCloud(merging: Bool = false) {
        guard let data = cloud.data(forKey: Self.cloudKey),
              let remote = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        offsets = merging ? offsets.merging(remote) { _, cloudValue in cloudValue } : remote
        if let encoded = try? JSONEncoder().encode(offsets) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        offsets = loaded
    }
}
