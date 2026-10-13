import Foundation

/// Holds the tall artwork for the current track and the next one in the queue, so the
/// next track's lookup, first frame and color are ready before it starts.
@Observable
@MainActor
final class TallArtworkStore {
    static let shared = TallArtworkStore()

    private(set) var current = TallArtworkModel()
    private var next: TallArtworkModel?
    private var isActive = false

    private static func key(_ track: PlexMetadata?) -> String? {
        guard let track, !track.albumName.isEmpty else { return nil }
        return "\(track.artistName)|\(track.albumName)"
    }

    /// Call whenever the current track or queue changes.
    func update(from player: AudioPlayerService) {
        let currentTrack = player.currentTrack
        let nextIndex = player.currentIndex + 1
        let nextTrack = player.queue.indices.contains(nextIndex) ? player.queue[nextIndex] : nil
        let currentKey = Self.key(currentTrack)
        let nextKey = Self.key(nextTrack)

        if current.key != currentKey {
            current.reset()
            if let next, next.key == currentKey {
                current = next
                self.next = nil
                if isActive { current.activate() }
            }
        }
        current.prefetch(artist: currentTrack?.artistName ?? "", album: currentTrack?.albumName ?? "")

        if nextKey == nil || nextKey == currentKey {
            next?.reset()
            next = nil
        } else if next?.key != nextKey {
            next?.reset()
            let model = TallArtworkModel()
            model.prefetch(artist: nextTrack?.artistName ?? "", album: nextTrack?.albumName ?? "")
            next = model
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
