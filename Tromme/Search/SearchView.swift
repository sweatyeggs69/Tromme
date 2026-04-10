import SwiftUI

struct SearchView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    @State private var searchText = ""
    @State private var hubs: [Hub] = []
    @State private var isSearching = false

    var body: some View {
        Group {
            if searchText.isEmpty && hubs.isEmpty {
                ContentUnavailableView(
                    "Search Music",
                    systemImage: "magnifyingglass",
                    description: Text("Search for artists, albums, and songs.")
                )
            } else if isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hubs.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(hubs) { hub in
                        if let items = hub.metadata, !items.isEmpty {
                            Section(hub.title ?? "Results") {
                                ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { index, item in
                                    searchResultRow(item: item, allItems: items, index: index)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Artists, Songs, Albums & More")
        .onChange(of: searchText) { _, newValue in
            Task { await performSearch(query: newValue) }
        }
    }

    @ViewBuilder
    private func searchResultRow(item: PlexMetadata, allItems: [PlexMetadata], index: Int) -> some View {
        switch item.type {
        case "artist":
            NavigationLink(value: item) {
                HStack(spacing: 12) {
                    ArtworkView(thumbPath: item.thumb, size: 44, cornerRadius: 22)
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text("Artist").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case "album":
            NavigationLink(value: item) {
                HStack(spacing: 12) {
                    ArtworkView(thumbPath: item.thumb, size: 44, cornerRadius: 6)
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text(item.parentTitle ?? "Album").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        default:
            let trackItems = allItems.filter { $0.type == "track" }
            let trackIndex = trackItems.firstIndex(where: { $0.ratingKey == item.ratingKey }) ?? 0
            TrackRowView(
                track: item,
                tracks: trackItems,
                index: trackIndex,
                showArtwork: true,
                showArtist: true,
                showTrackNumber: false
            )
        }
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty else {
            hubs = []
            return
        }
        guard let server = serverConnection.currentServer else { return }

        isSearching = true
        do {
            hubs = try await client.cachedSearch(
                server: server,
                query: query,
                sectionId: serverConnection.currentLibrarySectionId
            )
        } catch {
            hubs = []
        }
        isSearching = false
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .environment(AudioPlayerService())
}
