import SwiftUI

struct HomeHubsSettingsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage(HomeHubConfig.orderKey) private var hubOrderRaw = ""
    @AppStorage(HomeHubConfig.enabledKey) private var hubsEnabledRaw = ""

    @State private var availableHubs: [Hub] = []
    @State private var didLoadHubs = false

    private var orderedHubs: [Hub] {
        HomeHubConfig.ordered(availableHubs, by: HomeHubConfig.ids(hubOrderRaw))
    }

    private var selection: Binding<Set<String>> {
        Binding(
            get: { Set(HomeHubConfig.ids(hubsEnabledRaw)) },
            set: { hubsEnabledRaw = HomeHubConfig.raw(Array($0)) }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(orderedHubs) { hub in
                    Text(HomeHubConfig.displayTitle(for: hub))
                        .tag(HomeHubConfig.stableID(for: hub) ?? "")
                }
                .onMove(perform: moveHubs)
            } footer: {
                Text("Checked hubs show on Home above Playlists. Drag to reorder.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .tint(.green)
        .overlay {
            if orderedHubs.isEmpty {
                if didLoadHubs {
                    ContentUnavailableView("No Hubs", systemImage: "square.stack")
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Hubs")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: serverConnection.currentLibrarySectionId) {
            await loadHubs()
        }
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
        HomeHubsSettingsView()
    }
}
