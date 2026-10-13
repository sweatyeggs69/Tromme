import Foundation

/// Holds the tall artwork for the current track and its neighbors in the queue (previous
/// and next), so skipping either way lands on artwork whose lookup, first frame and color
/// are already ready.
@Observable
@MainActor
final class TallArtworkStore {
    static let shared = TallArtworkStore()

    private(set) var current = TallArtworkModel()
    /// Prefetched models for the previous and next tracks' albums, keyed by album key.
    private var neighbors: [String: TallArtworkModel] = [:]
    private var isActive = false

    private static func key(_ track: PlexMetadata?) -> String? {
        guard let track, !track.albumName.isEmpty else { return nil }
        return "\(track.artistName)|\(track.albumName)"
    }

    /// Call whenever the current track or queue changes.
    func update(from player: AudioPlayerService) {
        func track(at index: Int) -> PlexMetadata? {
            player.queue.indices.contains(index) ? player.queue[index] : nil
        }
        let currentTrack = player.currentTrack
        let currentKey = Self.key(currentTrack)
        var wanted: [String: PlexMetadata] = [:]
        for neighbor in [track(at: player.currentIndex - 1), track(at: player.currentIndex + 1)] {
            if let neighbor, let key = Self.key(neighbor), key != currentKey { wanted[key] = neighbor }
        }

        if current.key != currentKey {
            let old = current
            if let currentKey, let ready = neighbors.removeValue(forKey: currentKey) {
                current = ready
            } else {
                current = TallArtworkModel()
            }
            if isActive { current.activate() }
            // Keep the outgoing album around if it's still a neighbor, so skipping back is instant.
            if let oldKey = old.key, wanted[oldKey] != nil, neighbors[oldKey] == nil {
                old.deactivate()
                neighbors[oldKey] = old
            } else {
                retire(old)
            }
        }
        current.prefetch(artist: currentTrack?.artistName ?? "", album: currentTrack?.albumName ?? "")

        for key in neighbors.keys where wanted[key] == nil {
            neighbors.removeValue(forKey: key)?.reset()
        }
        for (key, track) in wanted where neighbors[key] == nil {
            let model = TallArtworkModel()
            model.prefetch(artist: track.artistName, album: track.albumName)
            neighbors[key] = model
        }
    }

    /// Keeps the outgoing model rendering while its layer fades out, then releases it.
    private func retire(_ model: TallArtworkModel) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            model.reset()
        }
    }

    /// Now Playing opened or the app became active.
    func activate() {
        isActive = true
        current.activate()
    }

    /// Now Playing closed or the app left the foreground.
    func deactivate() {
        isActive = false
        current.deactivate()
    }
}
