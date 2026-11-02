import SwiftUI

struct HomeSettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "large"
    @AppStorage("hideEmptySections") private var hideEmptySections = false
    @AppStorage(HomeHubConfig.orderKey) private var hubOrderRaw = ""
    @AppStorage(HomeHubConfig.hiddenSectionsKey) private var hiddenSectionsRaw = ""
    @AppStorage(HomeHubConfig.recentlyPlayedLevelKey) private var recentlyPlayedLevel = "songs"

    @Environment(\.editMode) private var editMode
    @State private var availableHubs: [Hub] = []

    private var orderedHubs: [Hub] {
        HomeHubConfig.ordered([HomeHubConfig.favorites] + availableHubs + [HomeHubConfig.playlists], by: HomeHubConfig.ids(hubOrderRaw))
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
                ForEach(orderedHubs) { hub in
                    hubRow(hub)
                }
                .onMove(perform: moveHubs)
            } header: {
                Text("Sections")
            } footer: {
                Text("Choose and order the sections on Home. Tap Edit to enable, disable or reorder them.")
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
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .task(id: serverConnection.currentLibrarySectionId) {
            await loadHubs()
        }
    }

    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }

    private func hubRow(_ hub: Hub) -> some View {
        let isEnabled = HomeHubConfig.isEnabled(hub, hiddenRaw: hiddenSectionsRaw)
        return Button {
            guard isEditing else { return }
            HomeHubConfig.setEnabled(hub, !isEnabled, hiddenRaw: &hiddenSectionsRaw)
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
            return
        }
        if let hubs = try? await client.getSectionHubs(server: server, sectionId: sectionId) {
            availableHubs = HomeHubConfig.uniqueByKind(hubs.filter(HomeHubConfig.isSupported))
        }
    }
}

#Preview {
    NavigationStack {
        HomeSettingsView()
    }
}
