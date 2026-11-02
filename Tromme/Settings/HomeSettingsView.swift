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
                }
            } header: {
                Text("Hubs")
            } footer: {
                Text("Show Plex hubs on Home above Playlists. Touch and hold a hub to reorder it.")
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
        .task(id: serverConnection.currentLibrarySectionId) {
            await loadHubs()
        }
    }

    private func hubRow(_ hub: Hub) -> some View {
        let id = HomeHubConfig.stableID(for: hub) ?? ""
        let isEnabled = HomeHubConfig.ids(hubsEnabledRaw).contains(id)
        return Button {
            var ids = HomeHubConfig.ids(hubsEnabledRaw).filter { $0 != id }
            if !isEnabled { ids.append(id) }
            hubsEnabledRaw = HomeHubConfig.raw(ids)
        } label: {
            HStack {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isEnabled ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(HomeHubConfig.displayTitle(for: hub))
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
            }
        }
        .buttonStyle(.plain)
        .draggable(id)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first else { return false }
            moveHub(dragged, onto: id)
            return true
        }
    }

    private func moveHub(_ draggedID: String, onto targetID: String) {
        var ids = orderedHubs.compactMap(HomeHubConfig.stableID(for:))
        guard draggedID != targetID,
              let from = ids.firstIndex(of: draggedID),
              let to = ids.firstIndex(of: targetID) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation { hubOrderRaw = HomeHubConfig.raw(ids) }
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
