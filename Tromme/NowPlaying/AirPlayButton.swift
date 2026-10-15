import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct AirPlayButton: UIViewRepresentable {
    var tintOpacity: CGFloat = 0.7
    var activeTintOpacity: CGFloat = 0.92
    var iconScale: CGFloat = 1.12
    var baseColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.tintColor = baseColor.withAlphaComponent(tintOpacity)
        picker.activeTintColor = baseColor.withAlphaComponent(activeTintOpacity)
        picker.prioritizesVideoDevices = false
        picker.transform = CGAffineTransform(scaleX: iconScale, y: iconScale)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = baseColor.withAlphaComponent(tintOpacity)
        uiView.activeTintColor = baseColor.withAlphaComponent(activeTintOpacity)
        uiView.transform = CGAffineTransform(scaleX: iconScale, y: iconScale)
    }
}
