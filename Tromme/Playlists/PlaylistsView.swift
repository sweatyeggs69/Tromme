import SwiftUI

struct PlaylistsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var playlists: [PlexPlaylist] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var isSearchPresented = false

    private var filteredPlaylists: [PlexPlaylist] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return playlists }
        return playlists.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Create playlists in Plex to see them here.")
                )
            } else if filteredPlaylists.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filteredPlaylists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(thumbPath: playlist.thumb ?? playlist.composite, size: 48, cornerRadius: 4)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.title)
                                        .appItemTitleStyle()
                                        .lineLimit(1)

                                    if let count = playlist.leafCount {
                                        Text("\(count) songs")
                                            .appItemSubtitleStyle()
                                    }
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(2)
            }
        }
        .navigationTitle("Playlists")
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search playlists"
        )
        .task { await loadPlaylists() }
        .refreshable { await loadPlaylists() }
        .onDisappear {
            searchText = ""
            isSearchPresented = false
        }
    }

    private func loadPlaylists() async {
        guard let server = serverConnection.currentServer else {
            playlists = []
            isLoading = false
            return
        }
        do {
            let all = try await client.cachedPlaylists(server: server)
            playlists = all.filter(\.isMusicPlaylist)
        } catch {
            playlists = []
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        PlaylistsView()
    }
}
