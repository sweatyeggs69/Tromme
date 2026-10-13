import AVFoundation
import SwiftUI

/// Tall video pinned to the top at full width (never cropped or zoomed), with a short
/// fade into a solid fill sampled from the video's bottom rows.
struct TallArtworkLayer: View {
    let model: TallArtworkModel

    /// Fraction of the video's height covered by the fade.
    private let fadeFraction: CGFloat = 0.15
    /// Fraction of the video's height that gets the progressive blur.
    private let blurFraction: CGFloat = 0.25

    var body: some View {
        ZStack(alignment: .top) {
            model.bottomColor
            VStack(spacing: 0) {
                Color.clear
                    .aspectRatio(TallArtworkModel.aspectRatio, contentMode: .fit)
                    .overlay {
                        if let player = model.player {
                            TallArtworkPlayerView(player: player, model: model)
                        }
                    }
                    .overlay {
                        // Progressive blur where the art meets the title, like Apple Music.
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .mask {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 1 - blurFraction),
                                        .init(color: .white, location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                    }
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: model.bottomColor.opacity(0), location: 1 - fadeFraction),
                                .init(color: model.bottomColor, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .clipped()
                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea()
        // Stay invisible until the video layer has a frame on screen, so the static cover
        // never shows through an empty video box.
        .opacity(model.isVideoDisplayed ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: model.isVideoDisplayed)
        .allowsHitTesting(false)
    }
}

private struct TallArtworkPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let model: TallArtworkModel

    final class Coordinator {
        var observation: NSKeyValueObservation?
        weak var model: TallArtworkModel?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        context.coordinator.model = model
        let model = model
        context.coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor in model.isVideoDisplayed = ready }
        }
        return view
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
        coordinator.observation = nil
        coordinator.model?.isVideoDisplayed = false
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

#Preview {
    TallArtworkLayer(model: TallArtworkModel())
        .background(Color.black)
}
