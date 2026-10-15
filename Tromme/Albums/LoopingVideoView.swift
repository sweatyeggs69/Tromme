import SwiftUI
import AVFoundation

/// A muted, looping video for `AnimatedArtworkView`. Restarts from the top whenever
/// `isPlaying` turns on, and sets `isReady` once playback has actually started
/// (buffered and rendering), so a slow stream never shows a stalled frame.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    @Binding var isReady: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isReady: $isReady) }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        context.coordinator.configure(url: url, layerView: view)
        context.coordinator.setPlaying(isPlaying)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
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
        private var isPlaying = false
        private let isReady: Binding<Bool>

        init(isReady: Binding<Bool>) { self.isReady = isReady }

        func configure(url: URL, layerView: PlayerLayerView) {
            tearDown()
            self.url = url
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            self.player = player
            layerView.playerLayer.player = player
            statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [isReady] player, _ in
                guard player.timeControlStatus == .playing else { return }
                Task { @MainActor in isReady.wrappedValue = true }
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

        func tearDown() {
            statusObservation = nil
            player?.pause()
            looper?.disableLooping()
            player = nil
            looper = nil
        }
    }
}
