import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct NowPlayingBackground: View {
    /// A still from the animated artwork; crossfades in over the static artwork.
    var animatedBackdrop: UIImage?

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var backgroundImage: UIImage?

    /// Blurred at a large radius, so a small thumbnail supplies plenty of quality —
    /// decoding/blurring the full 1000px artwork wastes CPU/GPU on every track change.
    /// The disk cache key ignores width/height, so this still shares the same
    /// on-disk file the crisp foreground artwork downloads.
    private static let blurredBackgroundPixelSize = 128

    private var thumbPath: String? {
        player.currentTrack?.parentThumb
    }

    private var backgroundURL: URL? {
        guard let thumbPath, let server = serverConnection.currentServer else { return nil }
        // Width/height here only influence the cache-miss download size (forced to at
        // least 1000px by ImageCache regardless); the same URL identity is shared with
        // the main Now Playing artwork's disk file.
        return client.artworkURL(server: server, path: thumbPath, width: ArtworkView.maxTranscodePx, height: ArtworkView.maxTranscodePx)
    }

    /// Prefer the State image (set after the async load); fall back to a synchronous
    /// in-memory cache peek so cached art renders on the first frame instead of
    /// flashing a placeholder color.
    private var resolvedImage: UIImage? {
        if let backgroundImage { return backgroundImage }
        guard let backgroundURL else { return nil }
        return ImageCache.shared.memoryCachedImage(for: backgroundURL, targetPixelSize: Self.blurredBackgroundPixelSize)
    }

    var body: some View {
        ZStack {
            Color.black
            if let resolvedImage {
                blurred(resolvedImage)
            }
            if let animatedBackdrop {
                blurred(animatedBackdrop)
                    .transition(.opacity)
            }
            Color.black.opacity(0.4)
        }
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: backgroundImage)
        .animation(.easeInOut(duration: 0.6), value: animatedBackdrop)
        .task(id: thumbPath) {
            guard let server = serverConnection.currentServer else { return }
            await loadBackgroundImage(server: server)
        }
    }

    private func blurred(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .blur(radius: 60)
            .scaleEffect(1.3)
    }

    private func loadBackgroundImage(server: PlexServer) async {
        let capturedThumb = thumbPath
        guard let capturedThumb,
              let url = client.artworkURL(server: server, path: capturedThumb, width: ArtworkView.maxTranscodePx, height: ArtworkView.maxTranscodePx) else {
            backgroundImage = nil
            return
        }
        let image = await ImageCache.shared.image(for: url, targetPixelSize: Self.blurredBackgroundPixelSize)
        guard !Task.isCancelled, capturedThumb == player.currentTrack?.parentThumb else { return }
        backgroundImage = image
    }
}
