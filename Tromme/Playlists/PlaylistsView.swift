import SwiftUI

struct PlaylistsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var playlists: [PlexPlaylist] = []
    @State private var isLoading = true

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
            } else {
                List(playlists) { playlist in
                    NavigationLink(value: playlist) {
                        HStack(spacing: 12) {
                            ArtworkView(thumbPath: playlist.composite, size: 56, cornerRadius: 6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.title)
                                    .font(.body)
                                    .lineLimit(1)
                                if let count = playlist.leafCount {
                                    Text("\(count) songs")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .task { await loadPlaylists() }
        .refreshable { await loadPlaylists() }
    }

    private func loadPlaylists() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            let all = try await client.cachedPlaylists(server: server)
            playlists = all.filter(\.isMusicPlaylist)
        } catch {
            // Handle error
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        PlaylistsView()
    }
}
