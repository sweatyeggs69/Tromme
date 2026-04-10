import SwiftUI

struct ArtistDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    let artist: PlexMetadata

    @State private var albums: [PlexMetadata] = []
    @State private var topTracks: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var showAllTopSongs = false
    @AppStorage("artistDetailAlbumViewMode") private var albumViewMode: ArtistDetailAlbumViewMode = .list

    private let albumGridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        List {
            // Play / Shuffle
            Section {
                HStack(spacing: 12) {
                    Button {
                        if !topTracks.isEmpty { player.play(tracks: topTracks) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if !topTracks.isEmpty {
                            var shuffled = topTracks
                            shuffled.shuffle()
                            player.play(tracks: shuffled)
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .listRowSeparator(.hidden)
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                // Top Songs
                if !topTracks.isEmpty {
                    Section("Top Songs") {
                        let displayTracks = showAllTopSongs ? topTracks : Array(topTracks.prefix(5))
                        ForEach(Array(displayTracks.enumerated()), id: \.element.id) { index, track in
                            let globalIndex = topTracks.firstIndex(where: { $0.ratingKey == track.ratingKey }) ?? index
                            TrackRowView(
                                track: track,
                                tracks: topTracks,
                                index: globalIndex,
                                showArtwork: true,
                                showTrackNumber: false
                            )
                        }
                        if topTracks.count > 5 {
                            Button(showAllTopSongs ? "Show Less" : "See All") {
                                withAnimation { showAllTopSongs.toggle() }
                            }
                        }
                    }
                }

                // Albums
                if !albums.isEmpty {
                    Section("Albums") {
                        switch albumViewMode {
                        case .list:
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    HStack(spacing: 12) {
                                        ArtworkView(thumbPath: album.thumb, size: 64, cornerRadius: 8)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.title)
                                                .appItemTitleStyle()
                                            if let year = album.year {
                                                Text(String(year))
                                                    .appItemSubtitleStyle()
                                            }
                                        }
                                    }
                                }
                            }

                        case .grid:
                            LazyVGrid(columns: albumGridColumns, spacing: 10) {
                                ForEach(albums) { album in
                                    NavigationLink(value: album) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ArtworkView(thumbPath: album.thumb, size: 160, cornerRadius: 8)

                                            Text(album.title)
                                                .appItemTitleStyle()

                                            if let year = album.year {
                                                Text(String(year))
                                                    .appItemSubtitleStyle()
                                            }
                                        }
                                        .frame(width: 160, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        }
        .navigationTitle(artist.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    albumViewMode = albumViewMode == .grid ? .list : .grid
                } label: {
                    Image(systemName: albumViewMode == .grid ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(albumViewMode == .grid ? "Show albums as list" : "Show albums as grid")
            }
        }
        .task { await loadContent() }
    }

    private func loadContent() async {
        guard let server = serverConnection.currentServer,
              serverConnection.currentLibrarySectionId != nil else { return }

        do {
            albums = try await client.cachedChildren(server: server, ratingKey: artist.ratingKey)
            albums.sort { ($0.year ?? 0) > ($1.year ?? 0) }

            var allTracks: [PlexMetadata] = []
            for album in albums.prefix(5) {
                let tracks = try await client.cachedChildren(server: server, ratingKey: album.ratingKey)
                allTracks.append(contentsOf: tracks)
            }
            topTracks = allTracks.sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
        } catch {}

        isLoading = false
    }
}

private enum ArtistDetailAlbumViewMode: String {
    case list
    case grid
}

#Preview {
    NavigationStack {
        ArtistDetailView(artist: PlexMetadata(
            ratingKey: "1", key: nil, type: "artist", title: "Radiohead",
            titleSort: nil, originalTitle: nil, summary: nil,
            year: nil, index: nil, parentIndex: nil, duration: nil,
            addedAt: nil, updatedAt: nil, viewCount: nil, lastViewedAt: nil,
            thumb: nil, art: nil, parentThumb: nil, grandparentThumb: nil,
            grandparentArt: nil, parentTitle: nil, grandparentTitle: nil,
            parentRatingKey: nil, grandparentRatingKey: nil,
            leafCount: nil, viewedLeafCount: nil, media: nil,
            genre: [PlexTag(tag: "Alternative")], country: nil
        ))
    }
    .environment(AudioPlayerService())
}
