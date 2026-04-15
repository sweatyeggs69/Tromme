import SwiftUI

struct HomeView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var favoriteTracks: [PlexMetadata]
    @State private var recentTracks: [PlexMetadata]
    @State private var recentAlbums: [PlexMetadata]
    @State private var isLoading: Bool

    private let previewRecentTracks: [PlexMetadata]?
    private let previewRecentAlbums: [PlexMetadata]?

    init(
        previewRecentTracks: [PlexMetadata]? = nil,
        previewRecentAlbums: [PlexMetadata]? = nil
    ) {
        self.previewRecentTracks = previewRecentTracks
        self.previewRecentAlbums = previewRecentAlbums
        _favoriteTracks = State(initialValue: Array((previewRecentTracks ?? []).prefix(10)))
        _recentTracks = State(initialValue: previewRecentTracks ?? [])
        _recentAlbums = State(initialValue: previewRecentAlbums ?? [])
        _isLoading = State(initialValue: previewRecentTracks == nil && previewRecentAlbums == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                favoritesSection
                recentlyAddedSection
                recentlyPlayedSection
            }
            .padding(.vertical, 8)
        }
        .task {
            guard previewRecentTracks == nil && previewRecentAlbums == nil else { return }
            await loadHomeContent(forceRefresh: false)
        }
        .refreshable {
            guard previewRecentTracks == nil && previewRecentAlbums == nil else { return }
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

    private func loadHomeContent(forceRefresh: Bool) async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else {
            favoriteTracks = []
            recentTracks = []
            recentAlbums = []
            isLoading = false
            return
        }

        if forceRefresh {
            // Clear cache so cachedTracks/cachedAlbums fetch fresh
            let tracksKey = CacheKey.tracks(serverId: server.machineIdentifier, sectionId: sectionId)
            let albumsKey = CacheKey.albums(serverId: server.machineIdentifier, sectionId: sectionId)
            await LibraryCache.shared.remove(forKey: tracksKey)
            await LibraryCache.shared.remove(forKey: albumsKey)
        }

        do {
            async let tracksReq = client.cachedTracks(server: server, sectionId: sectionId)
            async let albumsReq = client.cachedAlbums(server: server, sectionId: sectionId)
            async let favoritesReq: [PlexMetadata] = client.getFavoriteTracks(server: server, sectionId: sectionId)
            // Recently played is always fetched fresh from the server
            // since lastViewedAt changes with every play and stale cache data
            // would show outdated recently played
            async let recentlyPlayedReq: [PlexMetadata] = client.getRecentlyPlayed(server: server, sectionId: sectionId)

            let allTracks = try await tracksReq
            let allAlbums = try await albumsReq
            let plexFavorites = (try? await favoritesReq) ?? []
            let recentlyPlayed = (try? await recentlyPlayedReq) ?? []

            applyFavorites(allTracks: allTracks, plexFavorites: plexFavorites)
            recentTracks = Array(recentlyPlayed.prefix(10))
            recentAlbums = Array(
                allAlbums
                    .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
                    .prefix(10)
            )
        } catch {}

        isLoading = false
    }

    private func applyFavorites(allTracks: [PlexMetadata], plexFavorites: [PlexMetadata]) {
        let resolvedFavorites = plexFavorites.isEmpty
            ? allTracks.filter { ($0.userRating ?? 0) > 0 }
            : plexFavorites

        favoriteTracks = Array(
            resolvedFavorites
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
            previewRecentAlbums: DevelopmentMockData.recentAlbums
        )
    }
    .environment(AudioPlayerService())
}
#endif
