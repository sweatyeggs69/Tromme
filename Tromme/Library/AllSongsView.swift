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

    private var trackSections: [(title: String, items: [(index: Int, track: PlexMetadata)])] {
        var sections: [(title: String, items: [(index: Int, track: PlexMetadata)])] = []

        for item in filteredTracks.enumerated() {
            let title = alphabetSectionTitle(for: item.element.titleSort ?? item.element.title)
            if let index = sections.firstIndex(where: { $0.title == title }) {
                sections[index].items.append((index: item.offset, track: item.element))
            } else {
                sections.append((title: title, items: [(index: item.offset, track: item.element)]))
            }
        }

        return sections
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
                        ForEach(trackSections, id: \.title) { section in
                            Section(section.title) {
                                ForEach(section.items, id: \.track.id) { item in
                                    TrackRowView(
                                        track: item.track,
                                        tracks: filteredTracks,
                                        index: item.index,
                                        showArtwork: true,
                                        showArtist: true,
                                        showTrackNumber: false
                                    )
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                }
                            }
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

    private func alphabetSectionTitle(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let letter = String(first).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
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
