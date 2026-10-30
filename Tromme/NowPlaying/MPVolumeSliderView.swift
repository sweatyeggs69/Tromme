import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct MPVolumeSliderView: UIViewRepresentable {
    @Binding var volume: Float
    let isEnabled: Bool
    let isDragging: Bool

    final class Coordinator {
        var didSyncInitialVolume = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.isUserInteractionEnabled = false
        styleSubviews(in: view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // On first render, read back the real system volume from the MPVolumeView
        // slider to correct the visual display. AVAudioSession.outputVolume always
        // returns 1.0 on macOS Catalyst so we can't trust it for initialization.
        if !context.coordinator.didSyncInitialVolume {
            context.coordinator.didSyncInitialVolume = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.05))
                if let slider = uiView.subviews.compactMap({ $0 as? UISlider }).first {
                    volume = slider.value
                }
            }
        }
        guard isEnabled, isDragging else { return }
        for subview in uiView.subviews {
            if let slider = subview as? UISlider {
                slider.setValue(volume, animated: false)
                slider.sendActions(for: .valueChanged)
                return
            }
        }
    }

    private func styleSubviews(in view: MPVolumeView) {
        view.tintColor = .white
        for subview in view.subviews {
            if let slider = subview as? UISlider {
                slider.minimumTrackTintColor = .clear
                slider.maximumTrackTintColor = .clear
                slider.thumbTintColor = .clear
            } else if let button = subview as? UIButton {
                button.isHidden = true
            }
        }
    }
}
