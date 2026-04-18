import SwiftUI

struct AllSongsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var isSearchPresented = false
    private let previewTracks: [PlexMetadata]?

    init(previewTracks: [PlexMetadata]? = nil) {
        self.previewTracks = previewTracks
        _tracks = State(initialValue: previewTracks ?? [])
        _isLoading = State(initialValue: previewTracks == nil)
    }

    private var filteredTracks: [PlexMetadata] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }
        return tracks.filter { track in
            track.title.localizedCaseInsensitiveContains(query)
            || (track.grandparentTitle?.localizedCaseInsensitiveContains(query) ?? false)
            || (track.parentTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if filteredTracks.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { index, track in
                            TrackRowView(
                                track: track,
                                tracks: filteredTracks,
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
        }
        .navigationTitle("Songs")
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Filter songs"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    var shuffled = filteredTracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled)
                } label: {
                    Image(systemName: "shuffle")
                }
                .tint(.primary)
                .disabled(filteredTracks.isEmpty)
            }
        }
        .task {
            guard previewTracks == nil else { return }
            await loadTracks()
        }
        .onDisappear {
            searchText = ""
            isSearchPresented = false
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
