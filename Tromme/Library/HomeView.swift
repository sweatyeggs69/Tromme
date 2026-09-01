import SwiftUI

struct HomeView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @Environment(AudioPlayerService.self) private var player

    @State private var favoriteTracks: [PlexMetadata]
    @State private var recentTracks: [PlexMetadata]
    @State private var playlists: [PlexPlaylist]
    @State private var recentAlbums: [PlexMetadata]
    @State private var isLoading: Bool
    @State private var addToPlaylistItemKeys: [String] = []
    @State private var showingAddToPlaylistSheet = false
    @State private var featuredAlbums: [PlexMetadata]

    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("featuredBannerSize") private var featuredBannerSize = "immersive"
    @AppStorage("featuredAlbumRatingKeys") private var featuredAlbumRatingKeys: String = ""
    @AppStorage("featuredAlbumLastRefreshedAt") private var featuredAlbumLastRefreshedAt: Double = 0
    @AppStorage("hideEmptySections") private var hideEmptySections = false

    private var isImmersiveFeatured: Bool {
        showFeaturedSection && featuredBannerSize == "immersive" && NetworkStatus.shared.isConnected
    }

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
        _featuredAlbums = State(initialValue: Array((previewRecentAlbums ?? []).shuffled().prefix(5)))
        _isLoading = State(initialValue: previewRecentTracks == nil && previewPlaylists == nil && previewRecentAlbums == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showFeaturedSection && NetworkStatus.shared.isConnected {
                    featuredSection
                }
                if !hideEmptySections || isLoading || !favoriteTracks.isEmpty {
                    favoritesSection
                }
                recentlyAddedSection
                recentlyPlayedSection
                if !hideEmptySections || isLoading || !playlists.isEmpty {
                    playlistsSection
                }
            }
            .padding(.bottom, 8)
            .padding(.top, isImmersiveFeatured ? 0 : 8)
        }
        .ignoresSafeArea(.container, edges: isImmersiveFeatured ? .top : [])
        .refreshable {
            guard previewRecentTracks == nil && previewPlaylists == nil && previewRecentAlbums == nil else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await loadHomeContent(forceRefresh: true) }
                group.addTask { await loadFeaturedAlbum(forced: true) }
            }
        }
        .task(id: loadTaskID) {
            guard previewRecentTracks == nil && previewPlaylists == nil && previewRecentAlbums == nil else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await loadHomeContent(forceRefresh: false) }
                group.addTask { await loadFeaturedAlbum(forced: false) }
            }
        }
        .task {
            guard previewRecentTracks == nil else { return }
            for await _ in NotificationCenter.default.notifications(named: .favoritesDidChange) {
                guard !Task.isCancelled,
                      let server = serverConnection.currentServer,
                      let sectionId = serverConnection.currentLibrarySectionId else { continue }
                if let favorites = try? await client.cachedFavoriteTracks(server: server, sectionId: sectionId) {
                    applyFavorites(plexFavorites: favorites)
                    await LibraryCache.shared.set(
                        favoriteTracks,
                        forKey: CacheKey.homeFavorites(serverId: server.machineIdentifier, sectionId: sectionId)
                    )
                }
            }
        }
        .navigationTitle(serverConnection.currentServer?.name ?? "Home")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddToPlaylistSheet) {
            AddToPlaylistSheet(itemRatingKeys: addToPlaylistItemKeys)
        }
    }

    private var loadTaskID: String {
        let sectionID = serverConnection.currentLibrarySectionId ?? "none"
        let serverURI = serverConnection.currentServer?.uri ?? "none"
        let networkType = NetworkStatus.shared.interfaceType.map { "\($0)" } ?? "none"
        return "\(sectionID)|\(serverURI)|\(networkType)"
    }

    @ViewBuilder
    private var featuredSection: some View {
        if !featuredAlbums.isEmpty {
            FeaturedCarouselView(albums: featuredAlbums)
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Group {
                if !favoriteTracks.isEmpty {
                    NavigationLink {
                        FavoritesView()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Favorites")
                                .font(AppStyle.Typography.sectionTitle)
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .imageScale(.small)
                        }
                        .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                } else {
                    Text("Favorites")
                        .font(AppStyle.Typography.sectionTitle)
                }
            }
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)

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
                tracksHorizontalRow(tracks: favoriteTracks, showFavoriteStar: false)
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
                            .contextMenu {
                                albumContextMenu(for: album)
                            }
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

    private func tracksHorizontalRow(tracks: [PlexMetadata], showFavoriteStar: Bool = true) -> some View {
        HorizontalTrackGrid(tracks: tracks, showFavoriteStar: showFavoriteStar)
    }

    @ViewBuilder
    private func albumContextMenu(for album: PlexMetadata) -> some View {
        Button("Play Next", systemImage: "text.insert") {
            Task { await queueAlbumNext(album) }
        }
        Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
            Task { await queueAlbumLast(album) }
        }
        Button("Add to Playlist", systemImage: "text.badge.plus") {
            Task { await presentAddAlbumToPlaylist(album) }
        }
    }

    @MainActor
    private func queueAlbumNext(_ album: PlexMetadata) async {
        guard let server = serverConnection.currentServer else { return }
        guard let tracks = try? await client.cachedChildren(server: server, ratingKey: album.ratingKey), !tracks.isEmpty else { return }
        for track in tracks.reversed() {
            player.addToQueue(track)
        }
    }

    @MainActor
    private func queueAlbumLast(_ album: PlexMetadata) async {
        guard let server = serverConnection.currentServer else { return }
        guard let tracks = try? await client.cachedChildren(server: server, ratingKey: album.ratingKey), !tracks.isEmpty else { return }
        for track in tracks {
            player.addToEndOfQueue(track)
        }
    }

    @MainActor
    private func presentAddAlbumToPlaylist(_ album: PlexMetadata) async {
        guard let server = serverConnection.currentServer else { return }
        guard let tracks = try? await client.cachedChildren(server: server, ratingKey: album.ratingKey), !tracks.isEmpty else { return }
        addToPlaylistItemKeys = tracks.map(\.ratingKey)
        showingAddToPlaylistSheet = true
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Group {
                if !playlists.isEmpty {
                    NavigationLink {
                        PlaylistsView()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Playlists")
                                .font(AppStyle.Typography.sectionTitle)
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .imageScale(.small)
                        }
                        .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                } else {
                    Text("Playlists")
                        .font(AppStyle.Typography.sectionTitle)
                }
            }
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)

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

    private func loadFeaturedAlbum(forced: Bool) async {
        guard NetworkStatus.shared.isConnected else { return }
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        guard let albums = try? await client.cachedAlbums(server: server, sectionId: sectionId),
              !albums.isEmpty else { return }

        let oneHour: TimeInterval = 60 * 60
        let stale = (Date().timeIntervalSince1970 - featuredAlbumLastRefreshedAt) >= oneHour

        if forced || stale || featuredAlbumRatingKeys.isEmpty {
            var pool = albums
            var picked: [PlexMetadata] = []
            for _ in 0..<min(5, pool.count) {
                guard let idx = pool.indices.randomElement() else { break }
                picked.append(pool.remove(at: idx))
            }
            featuredAlbums = picked
            featuredAlbumRatingKeys = picked.map(\.ratingKey).joined(separator: ",")
            featuredAlbumLastRefreshedAt = Date().timeIntervalSince1970
        } else {
            let keys = featuredAlbumRatingKeys.split(separator: ",").map(String.init)
            let matched = keys.compactMap { key in albums.first { $0.ratingKey == key } }
            if !matched.isEmpty {
                featuredAlbums = matched
            }
        }
    }

    private func loadHomeContent(forceRefresh: Bool) async {
        // Pre-populate from memory cache synchronously (no actor hop needed).
        // Eliminates spinner flash when the memory cache is warm.
        if !forceRefresh,
           let server = serverConnection.currentServer,
           let sectionId = serverConnection.currentLibrarySectionId {
            let favKey = CacheKey.homeFavorites(serverId: server.machineIdentifier, sectionId: sectionId)
            let recentKey = CacheKey.homeRecentlyPlayed(serverId: server.machineIdentifier, sectionId: sectionId)
            let albumsKey = CacheKey.homeRecentlyAdded(serverId: server.machineIdentifier, sectionId: sectionId)
            let playlistsKey = CacheKey.homePlaylists(serverId: server.machineIdentifier)
            if let cached = LibraryCache.shared.memoryCached([PlexMetadata].self, forKey: favKey) { favoriteTracks = cached }
            if let cached = LibraryCache.shared.memoryCached([PlexMetadata].self, forKey: recentKey) { recentTracks = cached }
            if let cached = LibraryCache.shared.memoryCached([PlexMetadata].self, forKey: albumsKey) { recentAlbums = cached }
            if let cached = LibraryCache.shared.memoryCached([PlexPlaylist].self, forKey: playlistsKey) { playlists = cached }
        }

        let hadFavorites = !favoriteTracks.isEmpty
        let hadRecentTracks = !recentTracks.isEmpty
        let hadPlaylists = !playlists.isEmpty
        let hadRecentAlbums = !recentAlbums.isEmpty

        // Keep existing content visible during refresh; show loading spinners only
        // when there is no content yet.
        if !hadFavorites && !hadRecentTracks && !hadPlaylists && !hadRecentAlbums {
            isLoading = true
        }

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
            let playlistsKey = CacheKey.playlists(serverId: server.machineIdentifier)
            let homeFavoritesKey = CacheKey.homeFavorites(serverId: server.machineIdentifier, sectionId: sectionId)
            let homeRecentTracksKey = CacheKey.homeRecentlyPlayed(serverId: server.machineIdentifier, sectionId: sectionId)
            let homeRecentAlbumsKey = CacheKey.homeRecentlyAdded(serverId: server.machineIdentifier, sectionId: sectionId)
            let homePlaylistsKey = CacheKey.homePlaylists(serverId: server.machineIdentifier)
            await LibraryCache.shared.remove(forKey: tracksKey)
            await LibraryCache.shared.remove(forKey: albumsKey)
            await LibraryCache.shared.remove(forKey: playlistsKey)
            await LibraryCache.shared.remove(forKey: homeFavoritesKey)
            await LibraryCache.shared.remove(forKey: homeRecentTracksKey)
            await LibraryCache.shared.remove(forKey: homeRecentAlbumsKey)
            await LibraryCache.shared.remove(forKey: homePlaylistsKey)
        } else {
            await hydrateFromHomeCacheIfAvailable(server: server, sectionId: sectionId)
        }

        enum HomeLoadResult {
            case favorites([PlexMetadata]?)
            case recentlyPlayed([PlexMetadata]?)
            case playlists([PlexPlaylist]?)
            case recentlyAdded([PlexMetadata]?)
        }

        let loadResults: [HomeLoadResult] = await withTaskGroup(of: HomeLoadResult.self, returning: [HomeLoadResult].self) { group in
            group.addTask {
                let value = await fetchWithRetryOnFailure {
                    try await client.cachedFavoriteTracks(server: server, sectionId: sectionId)
                }
                return .favorites(value)
            }
            group.addTask {
                let value = await fetchWithRetryOnFailure {
                    try await client.getRecentlyPlayed(server: server, sectionId: sectionId, limit: 10)
                }
                return .recentlyPlayed(value)
            }
            group.addTask {
                let value = await fetchWithRetryOnFailure {
                    try await client.cachedPlaylists(server: server)
                }
                return .playlists(value)
            }
            group.addTask {
                let value = await fetchWithRetryOnFailure {
                    try await client.getRecentlyAdded(server: server, sectionId: sectionId, type: 9, limit: 10)
                }
                return .recentlyAdded(value)
            }

            var aggregated: [HomeLoadResult] = []
            for await result in group {
                aggregated.append(result)
            }
            return aggregated
        }

        var favoritesResult: [PlexMetadata]?
        var recentlyPlayedResult: [PlexMetadata]?
        var playlistsResult: [PlexPlaylist]?
        var recentlyAddedResult: [PlexMetadata]?
        for result in loadResults {
            switch result {
            case .favorites(let value): favoritesResult = value
            case .recentlyPlayed(let value): recentlyPlayedResult = value
            case .playlists(let value): playlistsResult = value
            case .recentlyAdded(let value): recentlyAddedResult = value
            }
        }

        guard !Task.isCancelled else { return }

        withAnimation(.easeIn(duration: 0.25)) {
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

            isLoading = false
        }

        if favoritesResult != nil {
            await LibraryCache.shared.set(
                favoriteTracks,
                forKey: CacheKey.homeFavorites(serverId: server.machineIdentifier, sectionId: sectionId)
            )
        }

        if recentlyPlayedResult != nil {
            await LibraryCache.shared.set(
                recentTracks,
                forKey: CacheKey.homeRecentlyPlayed(serverId: server.machineIdentifier, sectionId: sectionId)
            )
        }

        if playlistsResult != nil {
            await LibraryCache.shared.set(
                playlists,
                forKey: CacheKey.homePlaylists(serverId: server.machineIdentifier)
            )
        }

        if recentlyAddedResult != nil {
            await LibraryCache.shared.set(
                recentAlbums,
                forKey: CacheKey.homeRecentlyAdded(serverId: server.machineIdentifier, sectionId: sectionId)
            )
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

    private func fetchWithRetryOnFailure<T>(
        _ operation: () async throws -> T
    ) async -> T? {
        do {
            return try await operation()
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return nil }
                return try await operation()
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }
    }

    private func hydrateFromHomeCacheIfAvailable(server: PlexServer, sectionId: String) async {
        let favoritesKey = CacheKey.homeFavorites(serverId: server.machineIdentifier, sectionId: sectionId)
        let recentTracksKey = CacheKey.homeRecentlyPlayed(serverId: server.machineIdentifier, sectionId: sectionId)
        let recentAlbumsKey = CacheKey.homeRecentlyAdded(serverId: server.machineIdentifier, sectionId: sectionId)
        let playlistsKey = CacheKey.homePlaylists(serverId: server.machineIdentifier)

        if let cachedFavorites = await LibraryCache.shared.get([PlexMetadata].self, forKey: favoritesKey)?.value {
            withAnimation(.easeIn(duration: 0.25)) {
                favoriteTracks = cachedFavorites
                isLoading = false
            }
        }
        if let cachedRecentTracks = await LibraryCache.shared.get([PlexMetadata].self, forKey: recentTracksKey)?.value {
            withAnimation(.easeIn(duration: 0.25)) {
                recentTracks = cachedRecentTracks
                isLoading = false
            }
        }
        if let cachedRecentAlbums = await LibraryCache.shared.get([PlexMetadata].self, forKey: recentAlbumsKey)?.value {
            withAnimation(.easeIn(duration: 0.25)) {
                recentAlbums = cachedRecentAlbums
                isLoading = false
            }
        }
        if let cachedPlaylists = await LibraryCache.shared.get([PlexPlaylist].self, forKey: playlistsKey)?.value {
            withAnimation(.easeIn(duration: 0.25)) {
                playlists = cachedPlaylists
                isLoading = false
            }
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
        // Skip aggressive prefetching on metered networks or in Low Power Mode —
        // images will still load lazily as the user scrolls.
        guard !NetworkStatus.shared.isExpensive,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
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
