import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("leftAlignLyrics") private var leftAlignLyrics = false
    @AppStorage("lyricsTextSize") private var lyricsTextSize = "normal"
    @AppStorage(AnimatedArtworkEntitlement.settingKey) private var animatedArtworkEnabled = true
    @Environment(AudioPlayerService.self) private var player
    @State private var plus = PlusStore.shared

    private var canUseAnimatedArtwork: Bool {
        plus.isPlus && !NetworkStatus.shared.isConstrained
    }

    var body: some View {
        Form {
            Section {
                NavigationLink("App Icon") { AppIconPickerView() }
            }

            Section {
                Toggle("Animated Artwork", isOn: canUseAnimatedArtwork ? $animatedArtworkEnabled : .constant(false))
                    .tint(.green)
                    .disabled(!canUseAnimatedArtwork)
                    .onChange(of: animatedArtworkEnabled) { player.updateNowPlayingInfo() }
            } header: {
                Text("Albums")
            } footer: {
                if plus.isPlus, NetworkStatus.shared.isConstrained {
                    Text("Animated artwork is unavailable in Low Data Mode.")
                } else if plus.isPlus {
                    Text("Requires an internet connection.")
                }
            }

            Section {
                Picker("Text Size", selection: $lyricsTextSize) {
                    Text("Normal").tag("normal")
                    Text("Large").tag("large")
                }
                Toggle("Left Align Lyrics", isOn: $leftAlignLyrics)
                    .tint(.green)
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Large shows lyrics in a bigger font.")
            }
        }
        .navigationTitle("Appearance")
        .onChange(of: plus.isPlus) { player.updateNowPlayingInfo() }
        .onChange(of: NetworkStatus.shared.isConstrained) { player.updateNowPlayingInfo() }
    }
}

#Preview {
    NavigationStack {
        AppearanceSettingsView()
    }
    .environment(AudioPlayerService())
}
