import SwiftUI
import AVFoundation
import CoreImage

struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    var isHeld = false
    @Binding var isReady: Bool
    var onFrame: ((UIImage) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(isReady: $isReady) }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        context.coordinator.onFrame = onFrame
        context.coordinator.configure(url: url, layerView: view)
        context.coordinator.setPlaying(isPlaying, held: isHeld)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.onFrame = onFrame
        if context.coordinator.url != url {
            context.coordinator.configure(url: url, layerView: view)
        }
        context.coordinator.setPlaying(isPlaying, held: isHeld)
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
        private var itemObservation: NSKeyValueObservation?
        private var tracksObservation: NSKeyValueObservation?
        private var frameTask: Task<Void, Never>?
        var onFrame: ((UIImage) -> Void)?
        private var isPlaying = false
        private var isHeld = false
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
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                guard let item = player.currentItem else { return }
                Task { @MainActor in self?.disableAudio(of: item) }
            }
            if isPlaying, !isHeld { player.play() }
        }

        private func disableAudio(of item: AVPlayerItem) {
            tracksObservation = item.observe(\.tracks, options: [.initial, .new]) { item, _ in
                Task { @MainActor in
                    for track in item.tracks where track.assetTrack?.mediaType == .audio {
                        track.isEnabled = false
                    }
                }
            }
        }

        func setPlaying(_ playing: Bool, held: Bool) {
            let screenChanged = playing != isPlaying
            isPlaying = playing
            isHeld = held
            guard playing else {
                if screenChanged { player?.pause() }
                return
            }
            if screenChanged { player?.seek(to: .zero) }
            if held { player?.pause() } else { player?.play() }
        }

        private func captureFrame() {
            guard frameTask == nil, onFrame != nil, let item = player?.currentItem else { return }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: CVPixelBufferAttributes(rawAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]))
            item.add(output)
            frameTask = Task { [weak self] in
                defer { item.remove(output) }
                for _ in 0..<40 {
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    if let buffer = output.pixelBufferAndDisplayTime(forItemTime: time).pixelBuffer,
                       let image = buffer.withUnsafeBuffer({ Self.smallImage(from: $0) }) {
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
            itemObservation = nil
            tracksObservation = nil
            player?.pause()
            looper?.disableLooping()
            player = nil
            looper = nil
        }
    }
}
