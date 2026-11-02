import SwiftUI

struct HomeSettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "large"
    @AppStorage("hideEmptySections") private var hideEmptySections = false
    @AppStorage(HomeHubConfig.orderKey) private var hubOrderRaw = ""
    @AppStorage(HomeHubConfig.enabledKey) private var hubsEnabledRaw = ""

    @State private var availableHubs: [Hub] = []
    @State private var didLoadHubs = false

    private var orderedHubs: [Hub] {
        HomeHubConfig.ordered(availableHubs, by: HomeHubConfig.ids(hubOrderRaw))
    }

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
                if orderedHubs.isEmpty {
                    if didLoadHubs {
                        Text("No hubs available")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(orderedHubs) { hub in
                        Toggle(hub.title ?? "", isOn: enabledBinding(for: hub))
                            .tint(.green)
                    }
                    .onMove(perform: moveHubs)
                }
            } header: {
                Text("Hubs")
            } footer: {
                Text("Show Plex hubs below Playlists on Home. Tap Edit to reorder them.")
            }
        }
        .navigationTitle("Home")
        .toolbar {
            if !availableHubs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .task(id: serverConnection.currentLibrarySectionId) {
            await loadHubs()
        }
    }

    private func enabledBinding(for hub: Hub) -> Binding<Bool> {
        let id = HomeHubConfig.stableID(for: hub) ?? ""
        return Binding(
            get: { HomeHubConfig.ids(hubsEnabledRaw).contains(id) },
            set: { isOn in
                var ids = HomeHubConfig.ids(hubsEnabledRaw).filter { $0 != id }
                if isOn { ids.append(id) }
                hubsEnabledRaw = HomeHubConfig.raw(ids)
            }
        )
    }

    private func moveHubs(from source: IndexSet, to destination: Int) {
        var hubs = orderedHubs
        hubs.move(fromOffsets: source, toOffset: destination)
        hubOrderRaw = HomeHubConfig.raw(hubs.compactMap(HomeHubConfig.stableID(for:)))
    }

    private func loadHubs() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else {
            didLoadHubs = true
            return
        }
        if let hubs = try? await client.getSectionHubs(server: server, sectionId: sectionId) {
            availableHubs = hubs.filter(HomeHubConfig.isSupported)
        }
        didLoadHubs = true
    }
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
}
