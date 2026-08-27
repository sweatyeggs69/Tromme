import SwiftUI

struct HomeSettingsView: View {
    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "immersive"
    @AppStorage("showPopularTracks") private var showPopularTracks = false

    var body: some View {
        Form {
            Section("Home") {
                Toggle("Featured Section", isOn: $showFeaturedSection)
                    .tint(.green)
                if showFeaturedSection {
                    Picker("Size", selection: $featuredBannerSize) {
                        Text("Small").tag("small")
                        Text("Large").tag("large")
                        Text("Immersive").tag("immersive")
                    }
                }
            }

            Section("Albums") {
                Toggle("Popular Track Indicator", isOn: $showPopularTracks)
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
