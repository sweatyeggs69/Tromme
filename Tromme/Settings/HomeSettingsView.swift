import SwiftUI

struct HomeSettingsView: View {
    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "large"
    @AppStorage("hideEmptySections") private var hideEmptySections = false
    @AppStorage("leftAlignLyrics") private var leftAlignLyrics = false
    @AppStorage(AnimatedArtworkEntitlement.settingKey) private var animatedArtworkEnabled = true
    @Environment(AudioPlayerService.self) private var player
    @State private var plus = PlusStore.shared

    private var canUseAnimatedArtwork: Bool {
        plus.isPlus && !NetworkStatus.shared.isConstrained
    }

    var body: some View {
        Form {
            Section("Home") {
                Toggle("Featured Section", isOn: $showFeaturedSection)
                    .tint(.green)
                if showFeaturedSection {
                    Picker("Size", selection: $featuredBannerSize) {
                        Text("Small").tag("small")
                        Text("Large").tag("large")
                    }
                }
            }

            Section {
                Toggle("Hide Empty Sections", isOn: $hideEmptySections)
                    .tint(.green)
            }

            Section {
                Toggle("Animated Artwork", isOn: canUseAnimatedArtwork ? $animatedArtworkEnabled : .constant(false))
                    .tint(.green)
                    .disabled(!canUseAnimatedArtwork)
                    // Adds or removes it on the lock screen right away.
                    .onChange(of: animatedArtworkEnabled) { player.updateNowPlayingInfo() }
            } header: {
                Text("Albums")
            } footer: {
                if plus.isPlus, NetworkStatus.shared.isConstrained {
                    Text("Track popularity data is sourced from Last.fm. Animated artwork is unavailable in Low Data Mode.")
                } else if plus.isPlus {
                    Text("Track popularity data is sourced from Last.fm. Animated artwork requires an internet connection.")
                } else {
                    Text("Track popularity data is sourced from Last.fm. Animated artwork is part of Tromme +.")
                }
            }

            Section("Lyrics") {
                Toggle("Left Align Lyrics", isOn: $leftAlignLyrics)
                    .tint(.green)
            }
        }
        .navigationTitle("Interface")
        .onChange(of: plus.isPlus) { player.updateNowPlayingInfo() }
        .onChange(of: NetworkStatus.shared.isConstrained) { player.updateNowPlayingInfo() }
    }
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
    .environment(AudioPlayerService())
}
