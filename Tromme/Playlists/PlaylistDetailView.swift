import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    let playlist: PlexPlaylist

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true
    private let previewTracks: [PlexMetadata]?

    init(playlist: PlexPlaylist, previewTracks: [PlexMetadata]? = nil) {
        self.playlist = playlist
        self.previewTracks = previewTracks
        _tracks = State(initialValue: previewTracks ?? [])
        _isLoading = State(initialValue: previewTracks == nil)
    }

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
        .task {
            guard previewTracks == nil else { return }
            await loadTracks()
        }
    }

    private func loadTracks() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            tracks = try await client.cachedPlaylistItems(server: server, playlistKey: playlist.ratingKey)
        } catch {}
        isLoading = false
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PlaylistDetailView(
            playlist: DevelopmentMockData.previewPlaylist,
            previewTracks: DevelopmentMockData.previewPlaylistTracks
        )
    }
    .environment(AudioPlayerService())
}
#endif
