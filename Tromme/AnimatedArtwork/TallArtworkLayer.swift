import AVFoundation
import SwiftUI

/// Tall video pinned to the top at full width (never cropped or zoomed), with a short
/// fade into a solid fill sampled from the video's bottom rows.
struct TallArtworkLayer: View {
    let model: TallArtworkModel

    /// Fraction of the video's height covered by the fade.
    private let fadeFraction: CGFloat = 0.15

    var body: some View {
        ZStack(alignment: .top) {
            model.bottomColor
            VStack(spacing: 0) {
                Color.clear
                    .aspectRatio(TallArtworkModel.aspectRatio, contentMode: .fit)
                    .overlay {
                        if let player = model.player {
                            TallArtworkPlayerView(player: player)
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
        .allowsHitTesting(false)
    }
}

private struct TallArtworkPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
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
