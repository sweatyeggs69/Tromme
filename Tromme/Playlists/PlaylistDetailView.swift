import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    let playlist: PlexPlaylist

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true

    var body: some View {
        List {
            // Header
            Section {
                VStack(spacing: 12) {
                    ArtworkView(thumbPath: playlist.composite, size: 200, cornerRadius: 10)
                        .shadow(radius: 12, y: 6)

                    Text(playlist.title)
                        .font(.title3.bold())

                    if let count = playlist.leafCount {
                        Text("\(count) songs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }

            // Play / Shuffle
            Section {
                HStack(spacing: 12) {
                    Button {
                        player.play(tracks: tracks)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(tracks.isEmpty)

                    Button {
                        var shuffled = tracks
                        shuffled.shuffle()
                        player.play(tracks: shuffled)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(tracks.isEmpty)
                }
                .listRowSeparator(.hidden)
            }

            // Tracks
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRowView(
                            track: track,
                            tracks: tracks,
                            index: index,
                            showArtwork: true,
                            showArtist: true,
                            showTrackNumber: false
                        )
                    }
                }
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTracks() }
    }

    private func loadTracks() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            tracks = try await client.cachedPlaylistItems(server: server, playlistKey: playlist.ratingKey)
        } catch {}
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: PlexPlaylist(
            ratingKey: "1", key: nil, type: "playlist", title: "Favorites",
            summary: nil, smart: false, playlistType: "audio",
            composite: nil, duration: nil, leafCount: 24, addedAt: nil, updatedAt: nil
        ))
    }
    .environment(AudioPlayerService())
}
