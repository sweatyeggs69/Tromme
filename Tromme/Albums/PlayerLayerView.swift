import UIKit
import AVFoundation

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
