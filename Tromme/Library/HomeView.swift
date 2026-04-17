import SwiftUI

struct HomeView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var favoriteTracks: [PlexMetadata]
    @State private var recentTracks: [PlexMetadata]
    @State private var playlists: [PlexPlaylist]
    @State private var recentAlbums: [PlexMetadata]
    @State private var isLoading: Bool

    private let previewRecentTracks: [PlexMetadata]?
    private let previewPlaylists: [PlexPlaylist]?
    private let previewRecentAlbums: [PlexMetadata]?

    init(
        previewRecentTracks: [PlexMetadata]? = nil,
        previewPlaylists: [PlexPlaylist]? = nil,
        previewRecentAlbums: [PlexMetadata]? = nil
    ) {
        self.previewRecentTracks = previewRecentTracks
        self.previewPlaylists = previewPlaylists
        self.previewRecentAlbums = previewRecentAlbums
        _favoriteTracks = State(initialValue: Array((previewRecentTracks ?? []).prefix(10)))
        _recentTracks = State(initialValue: previewRecentTracks ?? [])
        _playlists = State(initialValue: previewPlaylists ?? [])
        _recentAlbums = State(initialValue: previewRecentAlbums ?? [])
        _isLoading = State(initialValue: previewRecentTracks == nil && previewPlaylists == nil && previewRecentAlbums == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                favoritesSection
                recentlyAddedSection
                recentlyPlayedSection
                playlistsSection
            }
            .padding(.vertical, 8)
        }
        .task(id: serverConnection.currentLibrarySectionId) {
            guard previewRecentTracks == nil && previewPlaylists == nil && previewRecentAlbums == nil else { return }
            await loadHomeContent(forceRefresh: false)
        }
        .refreshable {
            guard previewRecentTracks == nil && previewPlaylists == nil && previewRecentAlbums == nil else { return }
            await loadHomeContent(forceRefresh: true)
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Text("Favorites")
                .appSectionTitleStyle()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if favoriteTracks.isEmpty {
                ContentUnavailableView(
                    "No Favorites",
                    systemImage: "heart",
                    description: Text("Favorite songs in Plex to see them here.")
                )
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            } else {
                tracksHorizontalRow(tracks: favoriteTracks)
            }
        }
    }
    
    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Text("Recently Added")
                .appSectionTitleStyle()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if recentAlbums.isEmpty {
                ContentUnavailableView(
                    "No Recently Added",
                    systemImage: "square.stack",
                    description: Text("New albums and singles will appear here.")
                )
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(recentAlbums) { album in
                            NavigationLink(value: album) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(
                                        thumbPath: album.thumb,
                                        size: 170,
                                        cornerRadius: AppStyle.Radius.card
                                    )

                                    Text(album.title)
                                        .appItemTitleStyle()

                                    Text(album.parentTitle ?? "")
                                        .appItemSubtitleStyle()
                                }
                                .frame(width: 170, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
    
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Text("Recently Played")
                .appSectionTitleStyle()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if recentTracks.isEmpty {
                ContentUnavailableView(
                    "No Recently Played",
                    systemImage: "music.note.list",
                    description: Text("Play tracks to see them here.")
                )
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            } else {
                tracksHorizontalRow(tracks: recentTracks)
            }
        }
    }

    private func tracksHorizontalRow(tracks: [PlexMetadata]) -> some View {
        HorizontalTrackGrid(tracks: tracks)
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Text("Playlists")
                .appSectionTitleStyle()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Create playlists in Plex to see them here.")
                )
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: playlist) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(
                                        thumbPath: playlist.thumb ?? playlist.composite,
                                        size: 170,
                                        cornerRadius: AppStyle.Radius.card
                                    )

                                    Text(playlist.title)
                                        .appItemTitleStyle()

                                    if let count = playlist.leafCount {
                                        Text("\(count) songs")
                                            .appItemSubtitleStyle()
                                    } else {
                                        Text("")
                                            .appItemSubtitleStyle()
                                    }
                                }
                                .frame(width: 170, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private func loadHomeContent(forceRefresh: Bool) async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else {
            favoriteTracks = []
            recentTracks = []
            playlists = []
            recentAlbums = []
            isLoading = false
            return
        }

        if forceRefresh {
            let tracksKey = CacheKey.tracks(serverId: server.machineIdentifier, sectionId: sectionId)
            let albumsKey = CacheKey.albums(serverId: server.machineIdentifier, sectionId: sectionId)
            await LibraryCache.shared.remove(forKey: tracksKey)
            await LibraryCache.shared.remove(forKey: albumsKey)
        }

        async let favoritesReq: [PlexMetadata] = client.getFavoriteTracks(server: server, sectionId: sectionId)
        async let recentlyPlayedReq: [PlexMetadata] = client.getRecentlyPlayed(server: server, sectionId: sectionId, limit: 10)
        async let playlistsReq: [PlexPlaylist] = client.cachedPlaylists(server: server)
        async let recentlyAddedReq: [PlexMetadata] = client.getRecentlyAdded(server: server, sectionId: sectionId, type: 9, limit: 10)

        let plexFavorites = (try? await favoritesReq) ?? []
        let recentlyPlayed = (try? await recentlyPlayedReq) ?? []
        let allPlaylists = (try? await playlistsReq) ?? []
        let recentlyAdded = (try? await recentlyAddedReq) ?? []

        applyFavorites(plexFavorites: plexFavorites)
        recentTracks = Array(recentlyPlayed.prefix(10))
        playlists = Array(allPlaylists.filter(\.isMusicPlaylist).prefix(10))
        recentAlbums = Array(recentlyAdded.prefix(10))

        isLoading = false
    }

    private func applyFavorites(plexFavorites: [PlexMetadata]) {
        favoriteTracks = Array(
            plexFavorites
                .sorted {
                    if ($0.userRating ?? 0) == ($1.userRating ?? 0) {
                        return ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title)
                    }
                    return ($0.userRating ?? 0) > ($1.userRating ?? 0)
                }
                .prefix(10)
        )
    }

}

#if DEBUG
#Preview {
    NavigationStack {
        HomeView(
            previewRecentTracks: DevelopmentMockData.recentTracks,
            previewPlaylists: [DevelopmentMockData.previewPlaylist],
            previewRecentAlbums: DevelopmentMockData.recentAlbums
        )
    }
    .environment(AudioPlayerService())
}
#endif
