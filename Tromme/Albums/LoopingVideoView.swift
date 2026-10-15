import SwiftUI
import AVFoundation
import CoreImage

/// A muted, looping video for `AnimatedArtworkView`. Restarts from the top whenever
/// `isPlaying` turns on, and sets `isReady` once playback has actually started
/// (buffered and rendering), so a slow stream never shows a stalled frame. Hands
/// `onFrame` a small still of the video once it starts, for backdrops.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    @Binding var isReady: Bool
    var onFrame: ((UIImage) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(isReady: $isReady) }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        context.coordinator.onFrame = onFrame
        context.coordinator.configure(url: url, layerView: view)
        context.coordinator.setPlaying(isPlaying)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.onFrame = onFrame
        if context.coordinator.url != url {
            context.coordinator.configure(url: url, layerView: view)
        }
        context.coordinator.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        private(set) var url: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var statusObservation: NSKeyValueObservation?
        private var frameTask: Task<Void, Never>?
        var onFrame: ((UIImage) -> Void)?
        private var isPlaying = false
        private let isReady: Binding<Bool>

        init(isReady: Binding<Bool>) { self.isReady = isReady }

        func configure(url: URL, layerView: PlayerLayerView) {
            tearDown()
            self.url = url
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            self.looper = looper
            self.player = player
            layerView.playerLayer.player = player
            statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self, isReady] player, _ in
                guard player.timeControlStatus == .playing else { return }
                Task { @MainActor in
                    isReady.wrappedValue = true
                    self?.captureFrame()
                }
            }
            if isPlaying { player.play() }
        }

        func setPlaying(_ playing: Bool) {
            guard playing != isPlaying else { return }
            isPlaying = playing
            if playing {
                player?.seek(to: .zero)
                player?.play()
            } else {
                player?.pause()
            }
        }

        /// Grabs one frame per video, retrying briefly until the output has one. The
        /// output is attached to the item that's playing now: the looper creates its
        /// items asynchronously, so they don't exist yet when the video is configured.
        private func captureFrame() {
            guard frameTask == nil, onFrame != nil, let item = player?.currentItem else { return }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            frameTask = Task { [weak self] in
                defer { item.remove(output) }
                for _ in 0..<40 {
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                       let image = Self.smallImage(from: buffer) {
                        guard !Task.isCancelled else { return }
                        self?.onFrame?(image)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                #if DEBUG
                print("[AnimatedArtwork] no video frame for the backdrop")
                #endif
            }
        }

        /// Downscaled, since it's only used blurred.
        private static func smallImage(from buffer: CVPixelBuffer) -> UIImage? {
            var image = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 256 / max(image.extent.width, 1))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
            return UIImage(cgImage: cgImage)
        }

        func tearDown() {
            frameTask?.cancel()
            frameTask = nil
            statusObservation = nil
            player?.pause()
            looper?.disableLooping()
            player = nil
            looper = nil
        }
    }
}
