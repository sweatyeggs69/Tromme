import Foundation

/// Extension on PlexAPIClient providing cache-first access to library data.
/// Pattern: return cached data immediately if available. If stale or missing,
/// fetch from network and update cache. Concurrent requests for the same data
/// are coalesced via LibraryCache.withFetch so only one network call fires.
extension PlexAPIClient {

    // MARK: - Cached Library Sections

    func cachedLibrarySections(server: PlexServer) async throws -> [LibrarySection] {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.sections(serverId: server.machineIdentifier),
            policy: .detail
        ) {
            try await self.getLibrarySections(server: server)
        }
    }

    // MARK: - Cached Artists

    func cachedArtists(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        try await cachedLibraryContents(server: server, sectionId: sectionId, type: 8,
            key: CacheKey.artists(serverId: server.machineIdentifier, sectionId: sectionId))
    }

    // MARK: - Cached Albums

    func cachedAlbums(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        try await cachedLibraryContents(server: server, sectionId: sectionId, type: 9,
            key: CacheKey.albums(serverId: server.machineIdentifier, sectionId: sectionId))
    }

    func cachedArtistReleases(server: PlexServer, sectionId: String, artist: PlexMetadata) async throws -> [PlexMetadata] {
        var releases = try await cachedChildren(server: server, ratingKey: artist.ratingKey)
        let releaseKeys = Set(releases.map(\.ratingKey))
        let artistTracks = try await cachedArtistTracks(server: server, sectionId: sectionId, artist: artist)
        let missingReleaseKeys = Set(artistTracks.compactMap(\.parentRatingKey))
            .subtracting(releaseKeys)

        if !missingReleaseKeys.isEmpty {
            let missingReleases = await withTaskGroup(of: PlexMetadata?.self) { group in
                for key in missingReleaseKeys {
                    group.addTask {
                        try? await self.cachedMetadata(server: server, ratingKey: key)
                    }
                }

                var results: [PlexMetadata] = []
                for await release in group {
                    if let release {
                        results.append(release)
                    }
                }
                return results
            }
            releases.append(contentsOf: missingReleases)
        }

        var seenKeys = Set<String>()
        return releases
            .filter { seenKeys.insert($0.ratingKey).inserted }
            .sorted(by: releaseSort)
    }

    func cachedArtistTracks(server: PlexServer, sectionId: String, artist: PlexMetadata) async throws -> [PlexMetadata] {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.artistTracks(artistRatingKey: artist.ratingKey),
            policy: .detail
        ) {
            try await self.getArtistTracks(server: server, sectionId: sectionId, artistRatingKey: artist.ratingKey)
        }
    }


    // MARK: - Cached Favorite Tracks

    func cachedFavoriteTracks(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.favoriteTracks(serverId: server.machineIdentifier, sectionId: sectionId),
            policy: .userContent
        ) {
            try await self.getFavoriteTracks(server: server, sectionId: sectionId)
        }
    }

    // MARK: - Similar Artists

    /// Returns library artists that appear in Plex's curated Similar tags for the seed artist.
    func similarArtists(server: PlexServer, sectionId: String, seedArtistKey: String) async throws -> [PlexMetadata] {
        async let allArtistsTask = cachedArtists(server: server, sectionId: sectionId)
        async let seedMetadataTask = cachedMetadata(server: server, ratingKey: seedArtistKey)

        let allArtists = try await allArtistsTask
        let seedMetadata = try? await seedMetadataTask

        let similarTagNames = Set(
            (seedMetadata?.similar ?? [])
                .compactMap(\.tag)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )

        return allArtists.filter { artist in
            guard artist.ratingKey != seedArtistKey else { return false }
            return similarTagNames.contains(artist.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }.sorted { ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title) }
    }

    /// Albums from artists similar to `artistRatingKey`, sorted by release date.
    func albumsFromSimilarArtists(server: PlexServer, sectionId: String, artistRatingKey: String) async throws -> [PlexMetadata] {
        let similar = try await similarArtists(server: server, sectionId: sectionId, seedArtistKey: artistRatingKey)
        guard !similar.isEmpty else { return [] }

        let allAlbums = try await cachedAlbums(server: server, sectionId: sectionId)
        let similarArtistKeySet = Set(similar.map(\.ratingKey))

        return allAlbums
            .filter { similarArtistKeySet.contains($0.parentRatingKey ?? "") }
            .sorted(by: releaseSort)
    }

    // MARK: - Appears On Albums

    /// Albums where the given artist is credited as a featured performer but is not the primary artist.
    /// Uses the cached full track list and filters by `originalTitle` containing the artist name.
    func appearsOnAlbums(server: PlexServer, sectionId: String, artistRatingKey: String, artistTitle: String) async throws -> [PlexMetadata] {
        let allTracks = try await cachedTracks(server: server, sectionId: sectionId)
        let allAlbums = try await cachedAlbums(server: server, sectionId: sectionId)

        let artistTitleLower = artistTitle.lowercased()
        let featuredAlbumKeys = Set(
            allTracks.filter { track in
                guard track.grandparentRatingKey != artistRatingKey else { return false }
                guard let credit = track.originalTitle?.lowercased(), !credit.isEmpty else { return false }
                return credit.contains(artistTitleLower)
            }
            .compactMap(\.parentRatingKey)
        )

        guard !featuredAlbumKeys.isEmpty else { return [] }

        return allAlbums
            .filter { featuredAlbumKeys.contains($0.ratingKey) }
            .sorted { lhs, rhs in
                let leftDate = lhs.originallyAvailableAt ?? ""
                let rightDate = rhs.originallyAvailableAt ?? ""
                if leftDate != rightDate { return leftDate > rightDate }
                if (lhs.year ?? 0) != (rhs.year ?? 0) { return (lhs.year ?? 0) > (rhs.year ?? 0) }
                return (lhs.titleSort ?? lhs.title) < (rhs.titleSort ?? rhs.title)
            }
    }

    // MARK: - Cached Tracks

    func cachedTracks(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        try await cachedLibraryContents(server: server, sectionId: sectionId, type: 10,
            key: CacheKey.tracks(serverId: server.machineIdentifier, sectionId: sectionId))
    }

    // MARK: - Cached Top Tracks

    func cachedTopTracks(server: PlexServer, sectionId: String, artistRatingKey: String, limit: Int = 10) async throws -> [PlexMetadata] {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.topTracks(artistRatingKey: artistRatingKey),
            policy: .detail
        ) {
            try await self.getTopTracks(server: server, sectionId: sectionId, artistRatingKey: artistRatingKey, limit: limit)
        }
    }

    // MARK: - Cached Children (albums for artist, tracks for album)

    func cachedChildren(server: PlexServer, ratingKey: String) async throws -> [PlexMetadata] {
        let items: [PlexMetadata] = try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.children(ratingKey: ratingKey),
            policy: .detail
        ) {
            try await self.getMetadataChildren(server: server, ratingKey: ratingKey)
        }
        prefetchArtwork(for: items, server: server)
        return items
    }

    // MARK: - Cached Playlists

    func cachedPlaylists(server: PlexServer) async throws -> [PlexPlaylist] {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.playlists(serverId: server.machineIdentifier),
            policy: .userContent
        ) {
            try await self.getPlaylists(server: server)
        }
    }

    // MARK: - Cached Playlist Items

    func cachedPlaylistItems(server: PlexServer, playlistKey: String) async throws -> [PlexMetadata] {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.playlistItems(playlistKey: playlistKey),
            policy: .userContent
        ) {
            try await self.getPlaylistItems(server: server, playlistKey: playlistKey)
        }
    }

    // MARK: - Cached Search

    func cachedSearch(server: PlexServer, query: String, sectionId: String? = nil, limit: Int = 20) async throws -> [Hub] {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.search(query: query, sectionId: sectionId),
            policy: .search
        ) {
            try await self.search(server: server, query: query, sectionId: sectionId, limit: limit)
        }
    }

    // MARK: - Cached Metadata (single item)

    func cachedMetadata(server: PlexServer, ratingKey: String) async throws -> PlexMetadata? {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.metadata(ratingKey: ratingKey),
            policy: .detail
        ) {
            try await self.getMetadata(server: server, ratingKey: ratingKey)
        }
    }

    /// Album-detail metadata with a shorter disk lifetime so album summaries
    /// are refreshed at least once per day.
    func cachedAlbumMetadata(server: PlexServer, ratingKey: String) async throws -> PlexMetadata? {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.metadata(ratingKey: ratingKey),
            policy: .albumInfo
        ) {
            try await self.getMetadata(server: server, ratingKey: ratingKey)
        }
    }

    // MARK: - Cache Warming

    /// Preload the core library data (artists, albums, tracks) in parallel,
    /// then prefetch artwork for the loaded items.
    /// Uses request coalescing, so if views are already fetching, this joins those requests.
    func warmCache(server: PlexServer, sectionId: String) async {
        // Phase 1: Fetch library data in parallel
        var artists: [PlexMetadata] = []
        var albums: [PlexMetadata] = []
        var recentTracks: [PlexMetadata] = []
        var favoriteTracks: [PlexMetadata] = []

        await withTaskGroup(of: (String, [PlexMetadata]).self) { group in
            group.addTask { ("artists", (try? await self.cachedArtists(server: server, sectionId: sectionId)) ?? []) }
            group.addTask { ("albums", (try? await self.cachedAlbums(server: server, sectionId: sectionId)) ?? []) }
            group.addTask {
                _ = try? await self.cachedPlaylists(server: server)
                return ("playlists", [])
            }
            group.addTask { ("recent", (try? await self.getRecentlyPlayed(server: server, sectionId: sectionId, limit: 30)) ?? []) }
            group.addTask { ("favorites", (try? await self.cachedFavoriteTracks(server: server, sectionId: sectionId)) ?? []) }
            group.addTask {
                _ = try? await self.cachedTracks(server: server, sectionId: sectionId)
                return ("tracks", [])
            }

            for await (key, items) in group {
                switch key {
                case "artists": artists = items
                case "albums": albums = items
                case "recent": recentTracks = items
                case "favorites": favoriteTracks = items
                default: break
                }
            }
        }

        // Phase 2: Prefetch artwork for artists and albums in the background.
        // No-op on expensive/low-power — guard is inside prefetchArtwork.
        prefetchArtwork(for: artists + albums, server: server, size: 256)

        // Phases 3 and 4 are opportunistic prefetch that would flood a constrained connection.
        // On metered or low-power, let the cache warm organically as the user navigates.
        guard !NetworkStatus.shared.isExpensive,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }

        // Phase 3: Pre-fetch detail data for frequently accessed artists and albums.
        // Collect unique artist and album keys from recent + favorite tracks.
        var artistKeys = Set<String>()
        var albumKeys = Set<String>()
        for track in recentTracks + favoriteTracks {
            if let key = track.grandparentRatingKey { artistKeys.insert(key) }
            if let key = track.parentRatingKey { albumKeys.insert(key) }
        }

        let topArtistKeys = Array(artistKeys.prefix(25))
        let topAlbumKeys = Array(albumKeys.prefix(30))

        // Pre-fetch artist children (albums), artist metadata, and album children (tracks) in parallel.
        // Low concurrency to avoid saturating the server.
        await withTaskGroup(of: Void.self) { group in
            for key in topArtistKeys {
                group.addTask {
                    async let children = self.cachedChildren(server: server, ratingKey: key)
                    async let metadata = self.cachedMetadata(server: server, ratingKey: key)
                    async let topTracks = self.cachedTopTracks(server: server, sectionId: sectionId, artistRatingKey: key)
                    _ = try? await children
                    _ = try? await metadata
                    _ = try? await topTracks
                }
            }
            for key in topAlbumKeys {
                group.addTask {
                    async let children = self.cachedChildren(server: server, ratingKey: key)
                    async let metadata = self.cachedMetadata(server: server, ratingKey: key)
                    _ = try? await children
                    _ = try? await metadata
                }
            }
        }

        // Phase 4: Pre-extract artwork colors for those albums so detail views open instantly.
        let colorAlbums = albums.filter { albumKeys.contains($0.ratingKey) }
        let colorClient = self
        let colorServer = server
        for album in colorAlbums {
            await ArtworkColorCache.shared.resolveColor(
                for: album.thumb,
                using: colorClient,
                server: colorServer
            )
        }
    }

    // MARK: - Artwork Prefetching

    /// Build artwork URLs for metadata items and prefetch them into the image cache.
    /// Fires in the background so it doesn't block the caller.
    func prefetchArtwork(for items: [PlexMetadata], server: PlexServer, size: Int = 256) {
        guard !NetworkStatus.shared.isExpensive,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let maxPrefetchItems = 100
        var seen = Set<String>()
        let thumbPaths = items
            .compactMap(\.thumb)
            .filter { seen.insert($0).inserted }
            .prefix(maxPrefetchItems)
        guard !thumbPaths.isEmpty else { return }

        let urls = thumbPaths.compactMap { path in
            artworkURL(server: server, path: path, width: size, height: size)
        }

        Task(priority: .utility) {
            await ImageCache.shared.prefetch(urls: urls, targetPixelSize: size, maxConcurrent: 2)
        }
    }

    // MARK: - Private Helpers

    private func cachedLibraryContents(server: PlexServer, sectionId: String, type: Int, key: String) async throws -> [PlexMetadata] {
        let items: [PlexMetadata] = try await LibraryCache.shared.cachedFetch(
            forKey: key,
            policy: .library
        ) {
            try await self.getLibraryContents(server: server, sectionId: sectionId, type: type)
        }
        // Prefetch artwork for newly fetched items (artists/albums have thumb, tracks less important)
        if type == 8 || type == 9 {
            prefetchArtwork(for: items, server: server, size: 256)
        }
        return items
    }

    private func releaseSort(_ lhs: PlexMetadata, _ rhs: PlexMetadata) -> Bool {
        let leftDate = lhs.originallyAvailableAt ?? ""
        let rightDate = rhs.originallyAvailableAt ?? ""
        if leftDate != rightDate { return leftDate > rightDate }
        if (lhs.year ?? 0) != (rhs.year ?? 0) { return (lhs.year ?? 0) > (rhs.year ?? 0) }
        return (lhs.titleSort ?? lhs.title) < (rhs.titleSort ?? rhs.title)
    }

}
