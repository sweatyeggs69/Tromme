import SwiftUI

struct HomeSettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "large"
    @AppStorage("hideEmptySections") private var hideEmptySections = false
    @AppStorage(HomeHubConfig.orderKey) private var hubOrderRaw = ""
    @AppStorage(HomeHubConfig.enabledKey) private var hubsEnabledRaw = ""
    @AppStorage(HomeHubConfig.recentlyPlayedLevelKey) private var recentlyPlayedLevel = "songs"

    @Environment(\.editMode) private var editMode
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
                        hubRow(hub)
                    }
                    .onMove(perform: moveHubs)
                }
            } header: {
                Text("Hubs")
            } footer: {
                Text("Show Plex hubs on Home above Playlists. Tap Edit to enable, disable or reorder them.")
            }

            Section {
                Picker("Recently Played", selection: $recentlyPlayedLevel) {
                    Text("Songs").tag("songs")
                    Text("Artists").tag("artists")
                }
            } footer: {
                Text("Show recently played as individual songs or as the artists you listened to.")
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

    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }

    private func hubRow(_ hub: Hub) -> some View {
        let id = HomeHubConfig.stableID(for: hub) ?? ""
        let isEnabled = HomeHubConfig.ids(hubsEnabledRaw).contains(id)
        return Button {
            guard isEditing else { return }
            var ids = HomeHubConfig.ids(hubsEnabledRaw).filter { $0 != id }
            if !isEnabled { ids.append(id) }
            hubsEnabledRaw = HomeHubConfig.raw(ids)
        } label: {
            HStack {
                if isEditing {
                    Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isEnabled ? Color.green : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(HomeHubConfig.displayTitle(for: hub))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .animation(.default, value: isEnabled)
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
            HomeHubConfig.seedDefaultsIfNeeded(from: hubs)
            availableHubs = HomeHubConfig.uniqueByKind(hubs.filter(HomeHubConfig.isSupported))
        }
        didLoadHubs = true
    }
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
}
