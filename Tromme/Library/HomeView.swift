import SwiftUI

struct HomeView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale

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
        .task(id: loadTaskID) {
            guard previewRecentTracks == nil && previewPlaylists == nil && previewRecentAlbums == nil else { return }
            await loadHomeContent(forceRefresh: false)
        }
        .refreshable {
            guard previewRecentTracks == nil && previewPlaylists == nil && previewRecentAlbums == nil else { return }
            await loadHomeContent(forceRefresh: true)
        }
    }

    private var loadTaskID: String {
        let sectionID = serverConnection.currentLibrarySectionId ?? "none"
        let serverURI = serverConnection.currentServer?.uri ?? "none"
        return "\(sectionID)|\(serverURI)"
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
        let hadFavorites = !favoriteTracks.isEmpty
        let hadRecentTracks = !recentTracks.isEmpty
        let hadPlaylists = !playlists.isEmpty
        let hadRecentAlbums = !recentAlbums.isEmpty

        // Keep existing content visible during refresh; show loading spinners only
        // when there is no content yet.
        if !hadFavorites && !hadRecentTracks && !hadPlaylists && !hadRecentAlbums {
            isLoading = true
        }

        defer {
            isLoading = false
        }

        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else {
            favoriteTracks = []
            recentTracks = []
            playlists = []
            recentAlbums = []
            return
        }

        if forceRefresh {
            let tracksKey = CacheKey.tracks(serverId: server.machineIdentifier, sectionId: sectionId)
            let albumsKey = CacheKey.albums(serverId: server.machineIdentifier, sectionId: sectionId)
            let playlistsKey = CacheKey.playlists(serverId: server.machineIdentifier)
            await LibraryCache.shared.remove(forKey: tracksKey)
            await LibraryCache.shared.remove(forKey: albumsKey)
            await LibraryCache.shared.remove(forKey: playlistsKey)
        }

        async let favoritesReq: [PlexMetadata] = client.getFavoriteTracks(server: server, sectionId: sectionId)
        async let recentlyPlayedReq: [PlexMetadata] = client.getRecentlyPlayed(server: server, sectionId: sectionId, limit: 10)
        async let playlistsReq: [PlexPlaylist] = client.cachedPlaylists(server: server)
        async let recentlyAddedReq: [PlexMetadata] = client.getRecentlyAdded(server: server, sectionId: sectionId, type: 9, limit: 10)

        let favoritesResult = try? await favoritesReq
        let recentlyPlayedResult = try? await recentlyPlayedReq
        let playlistsResult = try? await playlistsReq
        let recentlyAddedResult = try? await recentlyAddedReq

        if let favoritesResult {
            applyFavorites(plexFavorites: favoritesResult)
        } else if !hadFavorites {
            favoriteTracks = []
        }

        if let recentlyPlayedResult {
            recentTracks = Array(recentlyPlayedResult.prefix(10))
        } else if !hadRecentTracks {
            recentTracks = []
        }

        if let playlistsResult {
            playlists = Array(playlistsResult.filter(\.isMusicPlaylist).prefix(10))
        } else if !hadPlaylists {
            playlists = []
        }

        if let recentlyAddedResult {
            recentAlbums = Array(recentlyAddedResult.prefix(10))
        } else if !hadRecentAlbums {
            recentAlbums = []
        }

        let snapshotFavorites = favoriteTracks
        let snapshotRecentTracks = recentTracks
        let snapshotPlaylists = playlists
        let snapshotRecentAlbums = recentAlbums
        Task(priority: .utility) {
            await prefetchHomeArtwork(
                server: server,
                favorites: snapshotFavorites,
                recentTracks: snapshotRecentTracks,
                playlists: snapshotPlaylists,
                recentAlbums: snapshotRecentAlbums
            )
        }
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

    private func prefetchHomeArtwork(
        server: PlexServer,
        favorites: [PlexMetadata],
        recentTracks: [PlexMetadata],
        playlists: [PlexPlaylist],
        recentAlbums: [PlexMetadata]
    ) async {
        let trackPixelSize = ArtworkView.recommendedTranscodeSize(
            pointSize: AppStyle.TrackGrid.artworkSize,
            displayScale: displayScale
        )
        let cardPixelSize = ArtworkView.recommendedTranscodeSize(
            pointSize: 170,
            displayScale: displayScale
        )

        let trackThumbPaths = (favorites + recentTracks)
            .compactMap { $0.thumb ?? $0.parentThumb }
        let cardThumbPaths = recentAlbums.compactMap(\.thumb) + playlists.compactMap { $0.thumb ?? $0.composite }

        var seen = Set<String>()
        let trackURLs = trackThumbPaths
            .filter { seen.insert("track:\($0)").inserted }
            .compactMap { path in
                client.artworkURL(server: server, path: path, width: trackPixelSize, height: trackPixelSize)
            }

        seen.removeAll(keepingCapacity: true)
        let cardURLs = cardThumbPaths
            .filter { seen.insert("card:\($0)").inserted }
            .compactMap { path in
                client.artworkURL(server: server, path: path, width: cardPixelSize, height: cardPixelSize)
            }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await ImageCache.shared.prefetch(urls: trackURLs, targetPixelSize: trackPixelSize, maxConcurrent: 4)
            }
            group.addTask {
                await ImageCache.shared.prefetch(urls: cardURLs, targetPixelSize: cardPixelSize, maxConcurrent: 4)
            }
        }
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
