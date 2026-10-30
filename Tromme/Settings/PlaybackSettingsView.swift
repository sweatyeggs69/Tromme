import SwiftUI

struct PlaybackSettingsView: View {
    @Environment(AudioPlayerService.self) private var player

    @State private var plus = PlusStore.shared
    @AppStorage("disableCellularTranscoding") private var disableCellularTranscoding = true
    @AppStorage("playbackBadgeMode") private var playbackBadgeMode = "off"
    @AppStorage("soundCheckEnabled") private var soundCheckEnabled = false
    @AppStorage("soundCheckGainSource") private var soundCheckGainSource = "track"
    @AppStorage("magicMixSeedCap") private var magicMixSeedCap = 1
    @AppStorage(AudioPlayerService.autoMixAllowedKey) private var autoMixAllowed = true
    @AppStorage(AudioPlayerService.crossfadeLengthKey) private var crossfadeSeconds = AutoMixPlanner.defaultCrossfadeLength

    var body: some View {
        Form {
            Section {
                Toggle("Infinite Mode", isOn: infiniteModeBinding)
                    .tint(.green)
            }

            Section {
                Picker("Seed Artist Tracks", selection: $magicMixSeedCap) {
                    Text("1x").tag(1)
                    Text("2x").tag(2)
                    Text("3x").tag(3)
                }
            } footer: {
                Text("Magic Mix blends the playing artist with similar artists. This sets how many of the playing artist's tracks it adds for each similar artist track.")
            }

            Section {
                if plus.isPlus {
                    Toggle("AutoMix", isOn: $autoMixAllowed)
                        .tint(.green)
                }
                Picker("Crossfade", selection: $crossfadeSeconds) {
                    ForEach([3.0, 5, 7, 10], id: \.self) { seconds in
                        Text("\(Int(seconds)) sec").tag(seconds)
                    }
                }
            } footer: {
                Text(plus.isPlus
                     ? "Turn off to use plain crossfade only. The queue button still switches mixing on and off."
                     : "How long songs overlap when crossfading.")
            }

            if supportsCellularSettings {
                Section {
                    Toggle("Cellular Transcoding", isOn: cellularTranscodingBinding)
                        .tint(.green)
                } footer: {
                    Text("Transcode streams to use less data on mobile networks.")
                }
            }

            Section {
                Picker("Show Codec/Bitrate", selection: $playbackBadgeMode) {
                    Text("Off").tag("off")
                    Text("Codec").tag("codec")
                    Text("Codec + Bitrate").tag("codecBitrate")
                }
            }

            Section {
                Toggle("Sound Check", isOn: $soundCheckEnabled)
                    .tint(.green)
                if soundCheckEnabled {
                    Picker("Gain Source", selection: $soundCheckGainSource) {
                        Text("Track").tag("track")
                        Text("Album").tag("album")
                    }
                }
            } footer: {
                Text("Keeps song volume more consistent using track or album gain.")
            }
        }
        .navigationTitle("Playback")
    }

    private var infiniteModeBinding: Binding<Bool> {
        Binding(
            get: { player.isInfiniteModeActive },
            set: { player.isInfiniteModeActive = $0 }
        )
    }

    private var cellularTranscodingBinding: Binding<Bool> {
        Binding(
            get: { !disableCellularTranscoding },
            set: { disableCellularTranscoding = !$0 }
        )
    }

    private var supportsCellularSettings: Bool {
        if UIDevice.current.userInterfaceIdiom == .phone {
            return true
        }
        return NetworkStatus.shared.isCellular || NetworkStatus.shared.interfaceType == .cellular
    }
}

#Preview {
    NavigationStack {
        PlaybackSettingsView()
            .environment(AudioPlayerService())
    }
}
