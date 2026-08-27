import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage("disableCellularTranscoding") private var disableCellularTranscoding = true
    @AppStorage("cellularTranscodeBitrateKbps") private var cellularTranscodeBitrateKbps = 320
    @AppStorage("playbackBadgeMode") private var playbackBadgeMode = "codecBitrate"
    @AppStorage("soundCheckEnabled") private var soundCheckEnabled = false
    @AppStorage("soundCheckGainSource") private var soundCheckGainSource = "track"

    private static let cellularTranscodeBitrateOptions: [Int] = [192, 256, 320]

    var body: some View {
        Form {
            Section {
                if supportsCellularSettings {
                    Toggle("Cellular Transcoding", isOn: cellularTranscodingBinding)
                        .tint(.green)
                    if cellularTranscodingBinding.wrappedValue {
                        Picker("Bitrate", selection: $cellularTranscodeBitrateKbps) {
                            ForEach(Self.cellularTranscodeBitrateOptions, id: \.self) { bitrate in
                                Text("\(bitrate) kbps").tag(bitrate)
                            }
                        }
                    }
                }
                Picker("Show Codec/Bitrate", selection: $playbackBadgeMode) {
                    Text("Off").tag("off")
                    Text("Codec").tag("codec")
                    Text("Codec + Bitrate").tag("codecBitrate")
                }
                Toggle("Sound Check", isOn: $soundCheckEnabled)
                    .tint(.green)
                if soundCheckEnabled {
                    Picker("Gain Source", selection: $soundCheckGainSource) {
                        Text("Track").tag("track")
                        Text("Album").tag("album")
                    }
                }
            } footer: {
                Text(footerText)
            }
        }
        .navigationTitle("Playback")
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

    private var footerText: String {
        if supportsCellularSettings {
            return "Enable transcoding to use less data on mobile networks. Sound Check can use track or album gain to keep volume consistent."
        }
        return "Sound Check keeps song volume more consistent using track or album gain."
    }
}

#Preview {
    NavigationStack {
        PlaybackSettingsView()
    }
}
