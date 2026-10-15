import AVFoundation
import MediaPlayer
import UIKit

/// Tromme+ animated artwork for the lock screen and system media controls. The
/// system only takes video files, so the current album's clips are downloaded on
/// demand into a temporary folder that is emptied whenever the album changes,
/// playback stops, or the app launches: nothing is ever kept.
@MainActor
final class NowPlayingAnimatedArtwork {
    static let shared = NowPlayingAnimatedArtwork()

    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "NowPlayingAnimatedArtwork", directoryHint: .isDirectory)
    private var albumKey: String?
    /// Bumped on every album change, so late lookups and downloads are discarded.
    private var generation = 0
    private var entries: [String: Any] = [:]
    private var lookupTask: Task<Void, Never>?
    private var downloads: [URL: Task<URL?, Never>] = [:]

    private init() {
        removeFiles()
    }

    /// The animated artwork Now Playing info entries for the track's album, once ready.
    func entries(for track: PlexMetadata) -> [String: Any] {
        Self.albumKey(for: track) == albumKey ? entries : [:]
    }

    /// Looks up the track's album on album change, then hands the entries to `apply`.
    func prepare(
        for track: PlexMetadata,
        previewImage: @escaping @Sendable (CGSize) async -> UIImage?,
        apply: @escaping @MainActor ([String: Any]) -> Void
    ) {
        let key = Self.albumKey(for: track)
        guard key != albumKey else { return }
        clear()
        albumKey = key
        guard AnimatedArtworkEntitlement.isEnabled,
              let artist = track.grandparentTitle, !artist.isEmpty,
              let album = track.parentTitle, !album.isEmpty else { return }
        let generation = generation
        lookupTask = Task {
            guard let artwork = await AnimatedArtworkService.artwork(artist: artist, album: album),
                  !Task.isCancelled, generation == self.generation else { return }
            // The system wants preview images quickly, so the static artwork is loaded up front.
            let staticPreview = await previewImage(.zero)
            guard !Task.isCancelled, generation == self.generation else { return }
            let supportedKeys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            #if DEBUG
            print("[AnimatedArtwork] lock screen keys supported: \(supportedKeys), square: \(artwork.square != nil), tall: \(artwork.tall != nil)")
            #endif
            var newEntries: [String: Any] = [:]
            if let square = artwork.square, supportedKeys.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
                newEntries[MPNowPlayingInfoProperty1x1AnimatedArtwork] = makeArtwork(
                    id: "\(key)|1x1", stream: square, generation: generation
                ) { _ in staticPreview }
            }
            // The preview must match the video's 3:4 shape or the system ignores the
            // artwork, so the tall one previews with the clip's own first frame.
            if let tall = artwork.tall, supportedKeys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
                newEntries[MPNowPlayingInfoProperty3x4AnimatedArtwork] = makeArtwork(
                    id: "\(key)|3x4", stream: tall, generation: generation
                ) { _ in
                    await NowPlayingAnimatedArtwork.shared.firstFrame(of: tall, generation: generation)
                }
            }
            entries = newEntries
            if !newEntries.isEmpty { apply(newEntries) }
        }
    }

    /// Drops the current album's animated artwork and deletes its temporary clips.
    func clear() {
        generation += 1
        albumKey = nil
        entries = [:]
        lookupTask?.cancel()
        lookupTask = nil
        downloads.values.forEach { $0.cancel() }
        downloads = [:]
        removeFiles()
    }

    private func makeArtwork(
        id: String,
        stream: URL,
        generation: Int,
        previewImage: @escaping @Sendable (CGSize) async -> UIImage?
    ) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(artworkID: id, previewImageRequestHandler: previewImage) { _ in
            #if DEBUG
            print("[AnimatedArtwork] system requested clip \(id)")
            #endif
            return await NowPlayingAnimatedArtwork.shared.clipFile(for: stream, generation: generation)
        }
    }

    /// The first frame of a clip, downloading the clip if needed.
    private func firstFrame(of stream: URL, generation: Int) async -> UIImage? {
        guard let file = await clipFile(for: stream, generation: generation) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: frame)
    }

    /// Downloads the clip the first time the system asks for it.
    private func clipFile(for stream: URL, generation: Int) async -> URL? {
        guard generation == self.generation else { return nil }
        if let download = downloads[stream] { return await download.value }
        let directory = directory
        let file = directory.appending(path: "\(UUID().uuidString).mp4")
        let download = Task.detached { () -> URL? in
            guard let data = await AnimatedArtworkClipDownloader.clipData(from: stream),
                  !Task.isCancelled else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return file
            } catch {
                return nil
            }
        }
        downloads[stream] = download
        let result = await download.value
        #if DEBUG
        print("[AnimatedArtwork] clip download \(result == nil ? "failed" : "finished"): \(stream.lastPathComponent)")
        #endif
        // The album changed mid-download: don't leave its clip behind.
        guard generation == self.generation else {
            if let result { try? FileManager.default.removeItem(at: result) }
            return nil
        }
        return result
    }

    private func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func albumKey(for track: PlexMetadata) -> String {
        "\(track.grandparentTitle ?? "")|\(track.parentTitle ?? "")"
    }
}
