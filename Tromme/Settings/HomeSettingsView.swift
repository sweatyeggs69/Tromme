import SwiftUI

struct HomeSettingsView: View {
    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "large"
    @AppStorage("showPopularTracks") private var showPopularTracks = true
    @AppStorage("hideEmptySections") private var hideEmptySections = false
    @AppStorage("leftAlignLyrics") private var leftAlignLyrics = false

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
            } header: {
                Text("Albums")
            } footer: {
                Text("Track popularity data is sourced from Last.fm.")
            }

            Section("Lyrics") {
                Toggle("Left Align Lyrics", isOn: $leftAlignLyrics)
                    .tint(.green)
            }
        }
        .navigationTitle("Interface")
    }
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
}
