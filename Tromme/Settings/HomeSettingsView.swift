import SwiftUI

struct HomeSettingsView: View {
    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "large"
    @AppStorage("showPopularTracks") private var showPopularTracks = true
    @AppStorage("hideEmptySections") private var hideEmptySections = false
    @AppStorage("leftAlignLyrics") private var leftAlignLyrics = false
    @AppStorage(AnimatedArtworkEntitlement.settingKey) private var animatedArtworkEnabled = true
    @Environment(AudioPlayerService.self) private var player
    @State private var plus = PlusStore.shared
    @State private var showPaywall = false

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
                Toggle("Popular Track Indicator", isOn: $showPopularTracks)
                    .tint(.green)
                if plus.isPlus {
                    Toggle("Animated Artwork", isOn: $animatedArtworkEnabled)
                        .tint(.green)
                        // Adds or removes it on the lock screen right away.
                        .onChange(of: animatedArtworkEnabled) { player.updateNowPlayingInfo() }
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        LabeledContent("Animated Artwork") {
                            Label("Tromme Plus", systemImage: "lock.fill")
                                .font(.subheadline)
                        }
                    }
                }
            } header: {
                Text("Albums")
            } footer: {
                if plus.isPlus {
                    Text("Track popularity data is sourced from Last.fm. Animated artwork plays on album pages and in Now Playing when an album has it, and requires an internet connection.")
                } else {
                    Text("Track popularity data is sourced from Last.fm.")
                }
            }

            Section("Lyrics") {
                Toggle("Left Align Lyrics", isOn: $leftAlignLyrics)
                    .tint(.green)
            }
        }
        .navigationTitle("Interface")
        .sheet(isPresented: $showPaywall) { PlusPaywallView() }
        .onChange(of: plus.isPlus) { player.updateNowPlayingInfo() }
    }
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
    .environment(AudioPlayerService())
}
