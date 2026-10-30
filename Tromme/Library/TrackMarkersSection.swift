import SwiftUI

struct TrackMarkersSection: View {
    let ratingKey: String
    let duration: TimeInterval

    private var player: AudioPlayerService { AppContext.shared.audioPlayer }

    private var store: TrackMarkerStore { AppContext.shared.trackMarkers }

    private var markers: TrackMarkers { store.markers(for: ratingKey) }

    private var isCurrentTrack: Bool { player.currentTrack?.ratingKey == ratingKey }

    private var start: Binding<Double> {
        Binding(
            get: { markers.start ?? 0 },
            set: { store.setStart($0, for: ratingKey) }
        )
    }

    private var stop: Binding<Double> {
        Binding(
            get: { markers.stop ?? duration },
            set: { store.setStop($0 >= duration ? nil : $0, for: ratingKey) }
        )
    }

    @State private var plus = PlusStore.shared
    @State private var showPaywall = false

    var body: some View {
        Section("Trim") {
            if plus.isPlus {
                controls
            } else {
                Button("Unlock with Tromme +", systemImage: "sparkles") { showPaywall = true }
            }
        }
        .sheet(isPresented: $showPaywall) { PlusPaywallView() }
    }

    @ViewBuilder
    private var controls: some View {
        Group {
            Stepper(value: start, in: 0...max(0, (markers.stop ?? duration) - 1), step: 1) {
                LabeledContent("Start", value: markers.start.map(Self.format) ?? "Off")
            }
            if isCurrentTrack {
                Button("Set Start to Current Time", systemImage: "arrow.down.to.line") {
                    store.setStart(min(player.currentTime, (markers.stop ?? duration) - 1), for: ratingKey)
                }
            }
            Stepper(value: stop, in: ((markers.start ?? 0) + 1)...max((markers.start ?? 0) + 1, duration), step: 1) {
                LabeledContent("Stop", value: markers.stop.map(Self.format) ?? "Off")
            }
            if isCurrentTrack {
                Button("Set Stop to Current Time", systemImage: "arrow.up.to.line") {
                    let time = max(player.currentTime, (markers.start ?? 0) + 1)
                    store.setStop(time >= duration ? nil : time, for: ratingKey)
                }
            }
            if !markers.isEmpty {
                Button("Reset", systemImage: "arrow.counterclockwise", role: .destructive) {
                    store.reset(for: ratingKey)
                }
            }
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

#Preview {
    Form { TrackMarkersSection(ratingKey: "1", duration: 215) }
}
