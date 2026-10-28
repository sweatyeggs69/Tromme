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
                    SliderTrack(progress: CGFloat(isEnabled ? volume : 0), isDragging: isDragging, width: geo.size.width)
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
        .defersSystemGestures(on: .bottom)
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
