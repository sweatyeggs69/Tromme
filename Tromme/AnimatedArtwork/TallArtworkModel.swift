import AVFoundation
import SwiftUI
import UIKit

/// Owns the tall animated artwork for the current album. It is prefetched when a track
/// starts, so Now Playing can open straight into the animated layout. `isReady` flips only
/// once a real frame is decoded and its bottom color sampled. The video plays only while
/// Now Playing is open (`isActive`); closed, it sits paused on its first frame.
@Observable
@MainActor
final class TallArtworkModel {
    /// Tall artwork is always 2048x2732.
    static let aspectRatio: CGFloat = 2048.0 / 2732.0

    private(set) var player: AVPlayer?
    private(set) var isReady = false
    private(set) var bottomColor: Color = .black

    private var loadTask: Task<Void, Never>?
    private var endObserver: (any NSObjectProtocol)?
    private(set) var key: String?

    /// Whether Now Playing is open and the app is active.
    private var isActive = false

    func prefetch(artist: String, album: String) {
        let newKey = "\(artist)|\(album)"
        guard newKey != key else { return }
        reset()
        key = newKey
        guard AnimatedArtworkEntitlement.isActive, !artist.isEmpty, !album.isEmpty else { return }
        loadTask = Task { await run(artist: artist, album: album) }
    }

    /// Now Playing opened or the app became active: restart from the first frame.
    func activate() {
        isActive = true
        restart()
    }

    /// Now Playing closed or the app left the foreground.
    func deactivate() {
        isActive = false
        player?.pause()
    }

    private func restart() {
        guard isActive, let player else { return }
        player.seek(to: .zero)
        player.play()
    }

    func reset() {
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
              !Task.isCancelled else {
            // Let a later open retry instead of sticking with a failed lookup.
            if !Task.isCancelled { key = nil }
            return
        }

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: CVPixelBufferAttributes(rawAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]))
        item.add(output)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
        player = newPlayer
        // Plays muted just long enough to decode a real frame for the color sample.
        newPlayer.play()

        // Wait for a real (non-black) frame; many clips open on black. Never show the layout before then.
        let deadline = Date().addingTimeInterval(10)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard newPlayer.timeControlStatus == .playing else { continue }
            let time = item.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let readOnly = output.pixelBufferAndDisplayTime(forItemTime: time).pixelBuffer,
                  let backdrop = readOnly.withUnsafeBuffer({ ArtworkBackdropColor(pixelBuffer: $0) }) else { continue }
            bottomColor = backdrop.color
            if isActive {
                withAnimation(.easeInOut(duration: 0.6)) { isReady = true }
            } else {
                newPlayer.pause()
                await newPlayer.seek(to: .zero)
                guard !Task.isCancelled else { return }
                isReady = true
            }
            return
        }
        // Timed out without a frame: fall back to static artwork.
        if !isReady { reset() }
    }
}
