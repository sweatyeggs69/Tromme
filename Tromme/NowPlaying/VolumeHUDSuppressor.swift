import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct VolumeHUDSuppressor: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
