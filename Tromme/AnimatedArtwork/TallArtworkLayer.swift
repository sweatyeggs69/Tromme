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
            let videoHeight = geo.size.width / TallArtworkModel.aspectRatio
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
        view.playerLayer.videoGravity = .resize
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        let playerLayer = AVPlayerLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// Pins the video to full width at 2048:2732 from the top, whatever size the host gives this view.
        override func layoutSubviews() {
            super.layoutSubviews()
            let height = bounds.width / TallArtworkModel.aspectRatio
            playerLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        }
    }
}

#Preview {
    TallArtworkLayer(model: TallArtworkModel())
        .background(Color.black)
}
