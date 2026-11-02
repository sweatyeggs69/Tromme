import SwiftUI

struct HomeSettingsView: View {
    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "large"
    @AppStorage("hideEmptySections") private var hideEmptySections = false
    @AppStorage(HomeHubConfig.recentlyPlayedLevelKey) private var recentlyPlayedLevel = "songs"

    var body: some View {
        Form {
            Section {
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
                NavigationLink("Hubs") { HomeHubsSettingsView() }
                Picker("Recently Played", selection: $recentlyPlayedLevel) {
                    Text("Songs").tag("songs")
                    Text("Artists").tag("artists")
                }
            } footer: {
                Text("Recently Played shows individual songs or the artists you listened to.")
            }
        }
        .navigationTitle("Home")
    }
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
}
