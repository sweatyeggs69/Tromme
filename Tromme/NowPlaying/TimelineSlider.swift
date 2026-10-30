import SwiftUI
import AVKit
import MediaPlayer
import UIKit

struct TimelineSlider: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var isDragging = false
    @State private var sliderValue: TimeInterval = 0
    @State private var dragStartValue: TimeInterval = 0

    var usesOverlayedTimeLabels = false

    @AppStorage("playbackBadgeMode") private var playbackBadgeMode = "off"

    private var showsBadge: Bool {
        player.isPlayingLocalDownload || (playbackBadgeMode != "off" && player.activeStreamCodec != nil)
    }

    var body: some View {
        let duration = max(player.duration, 1)
        let isReady = player.isReadyToPlay || player.hasTrack
        let liveValue = min(max(player.currentTime, 0), duration)
        let anchoredLiveValue: TimeInterval = (!player.isPlaying && !player.isReadyToPlay && liveValue < 1) ? 0 : liveValue
        let displayValue = isDragging ? sliderValue : anchoredLiveValue

        Group {
            if usesOverlayedTimeLabels {
                sliderControl(duration: duration, isReady: isReady)
                    .overlay(alignment: .bottom) {
                        timeLabels(displayValue: displayValue, duration: duration)
                            .overlay {
                                playbackBadge
                                    .opacity(showsBadge ? 1 : 0)
                                    .animation(.easeInOut(duration: 0.2), value: showsBadge)
                            }
                            .offset(y: 14)
                    }
            } else {
                VStack(spacing: 6) {
                    sliderControl(duration: duration, isReady: isReady)
                    timeLabels(displayValue: displayValue, duration: duration)
                        .overlay {
                            playbackBadge
                                .opacity(showsBadge ? 1 : 0)
                                .animation(.easeInOut(duration: 0.2), value: showsBadge)
                        }
                }
            }
        }
        .onChange(of: player.currentTime) { _, newValue in
            if !isDragging {
                let clamped = min(max(newValue, 0), duration)
                sliderValue = (!player.isPlaying && !player.isReadyToPlay && clamped < 1) ? 0 : clamped
            }
        }
        .onChange(of: player.currentTrack?.ratingKey) { _, _ in
            if !isDragging {
                sliderValue = anchoredLiveValue
            }
        }
        .onChange(of: player.duration) { _, newDuration in
            if !isDragging {
                sliderValue = min(sliderValue, max(newDuration, 0))
            }
        }
        .onAppear {
            sliderValue = player.currentTime
        }
    }

    private func sliderControl(duration: TimeInterval, isReady: Bool) -> some View {
        let progress = duration > 0 ? sliderValue / duration : 0

        return GeometryReader { geo in
            SliderTrack(progress: CGFloat(progress), isDragging: isDragging, width: geo.size.width, isMixing: player.isAutoMixing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = sliderValue
                        }
                        let width = max(1, geo.size.width)
                        let delta = (drag.translation.width / width) * duration
                        sliderValue = min(max(dragStartValue + delta, 0), duration)
                    }
                    .onEnded { _ in
                        isDragging = false
                        player.seek(to: sliderValue)
                    }
            )
        }
        .frame(height: 28)
        .disabled(!isReady)
        .opacity(isReady ? (isDragging || player.isAutoMixing ? 1.0 : 0.55) : 0.3)
        .animation(.easeInOut(duration: 0.2), value: isDragging)
        .animation(.easeInOut(duration: 0.5), value: player.isAutoMixing)
    }

    private func timeLabels(displayValue: TimeInterval, duration: TimeInterval) -> some View {
        HStack {
            Text(formatTime(displayValue))
            Spacer()
            Text("-\(formatTime(max(0, duration - displayValue)))")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.45))
        .monospacedDigit()
        .frame(height: 18)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var playbackBadge: some View {
        HStack(spacing: 3) {
            if player.isPlayingLocalDownload {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption2.weight(.medium))
                    .imageScale(.small)
            }
            if playbackBadgeMode != "off", let codec = player.activeStreamCodec {
                let bitrateText = (playbackBadgeMode == "codecBitrate" ? player.activeStreamBitrate.map { " · \($0) kbps" } : nil) ?? ""
                Text(codec + bitrateText)
                    .font(.caption2.weight(.medium))
            }
        }
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
    }
}
