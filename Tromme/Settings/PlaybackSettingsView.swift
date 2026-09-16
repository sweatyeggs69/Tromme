import SwiftUI

struct PlaybackSettingsView: View {
    @Environment(AudioPlayerService.self) private var player

    @AppStorage("disableCellularTranscoding") private var disableCellularTranscoding = true
    @AppStorage("cellularTranscodeBitrateKbps") private var cellularTranscodeBitrateKbps = 320
    @AppStorage("playbackBadgeMode") private var playbackBadgeMode = "off"
    @AppStorage("soundCheckEnabled") private var soundCheckEnabled = false
    @AppStorage("soundCheckGainSource") private var soundCheckGainSource = "track"

    private static let cellularTranscodeBitrateOptions: [Int] = [192, 256, 320]

    var body: some View {
        Form {
            Section {
                Toggle("Infinite Mode", isOn: infiniteModeBinding)
                    .tint(.green)
            } footer: {
                Text("Keeps music playing continuously when the queue is empty.")
            }

            if supportsCellularSettings {
                Section {
                    Toggle("Cellular Transcoding", isOn: cellularTranscodingBinding)
                        .tint(.green)
                    if cellularTranscodingBinding.wrappedValue {
                        Picker("Bitrate", selection: $cellularTranscodeBitrateKbps) {
                            ForEach(Self.cellularTranscodeBitrateOptions, id: \.self) { bitrate in
                                Text("\(bitrate) kbps").tag(bitrate)
                            }
                        }
                    }
                } footer: {
                    Text("Transcode high-bitrate files to use less data on mobile networks.")
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
                Text("Sound Check keeps song volume more consistent using track or album gain.")
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
