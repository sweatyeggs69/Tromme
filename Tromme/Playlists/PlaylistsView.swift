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
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: playlist) {
                                HStack(spacing: 12) {
                                    ArtworkView(thumbPath: playlist.thumb ?? playlist.composite, size: 72, cornerRadius: 8)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.title)
                                            .appItemTitleStyle()
                                            .lineLimit(1)

                                        if let count = playlist.leafCount {
                                            Text("\(count) songs")
                                                .appItemSubtitleStyle()
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("Playlists")
        .task { await loadPlaylists() }
        .refreshable { await loadPlaylists() }
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
