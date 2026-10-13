import AVFoundation
import SwiftUI

/// Tall video pinned to the top at full width (never cropped or zoomed), with a short
/// fade into a solid fill sampled from the video's bottom rows.
struct TallArtworkLayer: View {
    let model: TallArtworkModel

    /// Fraction of the video's height covered by the fade.
    private let fadeFraction: CGFloat = 0.15

    var body: some View {
        GeometryReader { geo in
            let videoHeight = geo.size.width / model.aspectRatio
            ZStack(alignment: .top) {
                model.bottomColor
                if let player = model.player {
                    TallArtworkPlayerView(player: player)
                        .frame(width: geo.size.width, height: videoHeight)
                        .clipped()
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [model.bottomColor.opacity(0), model.bottomColor],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: videoHeight * fadeFraction)
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
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
        view.playerLayer.masksToBounds = true
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
