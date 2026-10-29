import SwiftUI
import AVKit
import MediaPlayer
import UIKit
import CoreImage

struct NowPlayingBackground: View {
    /// A still from the animated artwork; crossfades in over the static artwork.
    var animatedBackdrop: UIImage?

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    /// Already blurred, so the screen never runs a live full-screen blur: that GPU/CPU
    /// load on open and dismiss can starve audio on slower devices.
    @State private var backgroundImage: UIImage?
    @State private var blurredBackdrop: UIImage?

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

    var body: some View {
        ZStack {
            Color.black
            if let backgroundImage {
                filled(backgroundImage)
            }
            if let blurredBackdrop {
                filled(blurredBackdrop)
                    .transition(.opacity)
            }
            Color.black.opacity(0.4)
        }
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: backgroundImage)
        .animation(.easeInOut(duration: 0.6), value: blurredBackdrop)
        .task(id: thumbPath) {
            guard let server = serverConnection.currentServer else { return }
            await loadBackgroundImage(server: server)
        }
        .task(id: animatedBackdrop) {
            guard let animatedBackdrop else {
                blurredBackdrop = nil
                return
            }
            let image = await Task.detached { Self.blur(animatedBackdrop) }.value
            guard !Task.isCancelled else { return }
            blurredBackdrop = image
        }
    }

    private func filled(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .scaleEffect(1.3)
    }

    /// Blurs once at the image's own (small) size; scaled up it matches a 60 pt blur.
    private nonisolated static func blur(_ image: UIImage) -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        let radius = 60 * input.extent.width / 390
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        guard let cgImage = CIContext().createCGImage(blurred, from: input.extent) else { return image }
        return UIImage(cgImage: cgImage)
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
        guard let image else {
            backgroundImage = nil
            return
        }
        let blurred = await Task.detached { Self.blur(image) }.value
        guard !Task.isCancelled else { return }
        backgroundImage = blurred
    }
}
