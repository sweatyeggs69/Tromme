import SwiftUI

struct AllSongsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true
    private let previewTracks: [PlexMetadata]?

    init(previewTracks: [PlexMetadata]? = nil) {
        self.previewTracks = previewTracks
        _tracks = State(initialValue: previewTracks ?? [])
        _isLoading = State(initialValue: previewTracks == nil)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRowView(
                            track: track,
                            tracks: tracks,
                            index: index,
                            showArtwork: true,
                            showArtist: true,
                            showTrackNumber: false
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(2)
            }
        }
        .navigationTitle("Songs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    var shuffled = tracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled)
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(tracks.isEmpty)
            }
        }
        .task {
            guard previewTracks == nil else { return }
            await loadTracks()
        }
    }

    private func loadTracks() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        do {
            tracks = try await client.cachedTracks(server: server, sectionId: sectionId)
            tracks.sort { ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title) }
        } catch {
            // Handle error
        }
        isLoading = false
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AllSongsView(previewTracks: DevelopmentMockData.allSongs)
    }
    .environment(AudioPlayerService())
}
#endif
