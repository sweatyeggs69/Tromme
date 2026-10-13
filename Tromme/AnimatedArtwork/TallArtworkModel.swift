import AVFoundation
import SwiftUI
import UIKit

/// Owns the tall animated artwork player for one Now Playing presentation.
/// `isReady` flips only once the video is playing and its bottom color is sampled,
/// so the static-to-animated switch is a single change.
@Observable
@MainActor
final class TallArtworkModel {
    /// Native size of the tall artwork.
    static let aspectRatio: CGFloat = 2048.0 / 2732.0

    private(set) var player: AVPlayer?
    private(set) var isReady = false
    private(set) var bottomColor: Color = .black

    private var loadTask: Task<Void, Never>?
    private var endObserver: (any NSObjectProtocol)?
    private var key: String?

    func load(artist: String, album: String) {
        let newKey = "\(artist)|\(album)"
        guard newKey != key else { return }
        stop()
        key = newKey
        guard AnimatedArtworkEntitlement.isActive, !artist.isEmpty, !album.isEmpty else { return }
        loadTask = Task { await run(artist: artist, album: album) }
    }

    func pause() { player?.pause() }

    func restart() {
        guard let player else { return }
        player.seek(to: .zero)
        player.play()
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        isReady = false
        key = nil
    }

    private func run(artist: String, album: String) async {
        guard let url = await AnimatedArtworkService.tallURL(artist: artist, album: album),
              !Task.isCancelled else { return }

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
        player = newPlayer
        newPlayer.play()

        // Wait for a real (non-black) frame; many clips open on black. Never show the layout before then.
        let deadline = Date().addingTimeInterval(10)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard newPlayer.timeControlStatus == .playing else { continue }
            let time = item.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                  let backdrop = ArtworkBackdropColor(pixelBuffer: buffer) else { continue }
            bottomColor = backdrop.color
            withAnimation(.easeInOut(duration: 0.6)) { isReady = true }
            return
        }
        // Timed out without a frame: fall back to static artwork.
        if !isReady { stop() }
    }
}
