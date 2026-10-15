import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct VolumeSlider: View {
    let isEnabled: Bool
    @State private var isDragging = false
    @State private var volume: Float = AVAudioSession.sharedInstance().outputVolume
    @State private var dragStartVolume: Float = 0

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 16, alignment: .center)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(height: isDragging ? 16 : 7)
                            .frame(maxHeight: .infinity)
                        Capsule()
                            .fill(.white)
                            .frame(width: max(0, geo.size.width * CGFloat(isEnabled ? volume : 0)), height: isDragging ? 16 : 7)
                            .frame(maxHeight: .infinity, alignment: .leading)
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDragging)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                if !isDragging {
                                    isDragging = true
                                    dragStartVolume = volume
                                }
                                let delta = Float(drag.translation.width / max(1, geo.size.width))
                                volume = min(max(dragStartVolume + delta, 0), 1)
                            }
                            .onEnded { _ in isDragging = false }
                    )
                }

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 22, alignment: .center)
            }
            .opacity(isDragging ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.2), value: isDragging)

            MPVolumeSliderView(volume: $volume, isEnabled: isEnabled, isDragging: isDragging)
                .frame(width: 1, height: 1)
                .opacity(0.001)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .task {
            await observeSystemVolume()
        }
    }

    private func observeSystemVolume() async {
        let audioSession = AVAudioSession.sharedInstance()
        final class Box: @unchecked Sendable { var obs: NSKeyValueObservation? }
        let box = Box()
        let stream = AsyncStream<Float> { continuation in
            box.obs = audioSession.observe(\.outputVolume, options: [.initial, .new]) { _, change in
                if let v = change.newValue { continuation.yield(v) }
            }
            continuation.onTermination = { _ in box.obs?.invalidate() }
        }
        for await value in stream {
            if !isDragging {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    volume = value
                }
            }
        }
    }
}

private struct MPVolumeSliderView: UIViewRepresentable {
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
        // Only push to the system while the user is actively dragging — never on
        // automatic re-renders, which prevents corrupting volume on open.
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

private struct VolumeHUDSuppressor: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
