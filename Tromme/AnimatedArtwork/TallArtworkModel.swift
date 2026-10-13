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

        // Wait for real content (many clips open on black), but don't wait forever.
        let deadline = Date().addingTimeInterval(10)
        var playingSince: Date?
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard newPlayer.timeControlStatus == .playing else { continue }
            let since = playingSince ?? Date()
            playingSince = since
            let time = item.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                  let sample = Self.bottomSample(of: buffer) else { continue }
            if sample.luminance < 0.03, Date().timeIntervalSince(since) < 3 { continue }
            bottomColor = Self.darkened(sample.color)
            withAnimation(.easeInOut(duration: 0.6)) { isReady = true }
            return
        }
        // Timed out without a frame: fall back to static artwork.
        if !isReady { stop() }
    }

    /// Average color of the bottom rows of the frame.
    private static func bottomSample(of buffer: CVPixelBuffer) -> (color: UIColor, luminance: CGFloat)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 8 else { return nil }
        var r = 0.0, g = 0.0, b = 0.0
        var count = 0.0
        for row in (height - 8)..<height {
            let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                b += Double(line[x * 4])
                g += Double(line[x * 4 + 1])
                r += Double(line[x * 4 + 2])
                count += 1
            }
        }
        let red = CGFloat(r / count / 255), green = CGFloat(g / count / 255), blue = CGFloat(b / count / 255)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return (UIColor(red: red, green: green, blue: blue, alpha: 1), luminance)
    }

    /// Keeps the artwork's hue but caps brightness so white controls stay readable.
    private static func darkened(_ color: UIColor) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: hue, saturation: saturation, brightness: min(brightness, 0.4))
    }
}
