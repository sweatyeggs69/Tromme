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
        let albums = try await cachedLibraryContents(server: server, sectionId: sectionId, type: 9,
            key: CacheKey.albums(serverId: server.machineIdentifier, sectionId: sectionId))
        Task { try? await cachedAlbumStyles(server: server, sectionId: sectionId) }
        return albums
    }

    // MARK: - Cached Album Styles

    func cachedAlbumStyles(server: PlexServer, sectionId: String) async throws -> [String: [String]] {
        let key = CacheKey.albumStyles(serverId: server.machineIdentifier, sectionId: sectionId)

        if let cached = await LibraryCache.shared.get([String: [String]].self, forKey: key),
           !cached.value.isEmpty {
            if !cached.isStale { return cached.value }
            Task { try? await refreshAlbumStyles(server: server, sectionId: sectionId, key: key) }
            return cached.value
        }

        return try await refreshAlbumStyles(server: server, sectionId: sectionId, key: key)
    }

    // MARK: - Magic Mix

    func magicMixTracks(
        server: PlexServer,
        sectionId: String,
        seedAlbumKey: String,
        seedArtistKey: String? = nil,
        limit: Int = 25,
        minMatchingStyles: Int = 1
    ) async throws -> [PlexMetadata] {
        guard limit > 0, minMatchingStyles > 0 else { return [] }

        let stylesByAlbum = try await cachedAlbumStyles(server: server, sectionId: sectionId)
        let allAlbums = try await cachedAlbums(server: server, sectionId: sectionId)

        var seedStyles = stylesByAlbum[seedAlbumKey] ?? []

        // Fallback 1: borrow styles from sibling albums by the same artist
        if seedStyles.isEmpty, let artistKey = seedArtistKey {
            let siblings = (try? await cachedChildren(server: server, ratingKey: artistKey)) ?? []
            for album in siblings where album.ratingKey != seedAlbumKey {
                if let styles = stylesByAlbum[album.ratingKey], !styles.isEmpty {
                    seedStyles.append(contentsOf: styles)
                }
            }
            seedStyles = deduplicateTags(seedStyles)
        }

        // Fallback 2: if still no styles, match by genre instead.
        // Fetch full metadata for reliable genre data (bulk list often omits it).
        var useGenreMatching = false
        var seedGenres = Set<String>()
        if seedStyles.isEmpty {
            var albumKeysToCheck: [String] = [seedAlbumKey]
            if let artistKey = seedArtistKey {
                let siblings = (try? await cachedChildren(server: server, ratingKey: artistKey)) ?? []
                albumKeysToCheck.append(contentsOf: siblings.map(\.ratingKey))
            }
            // Fetch full metadata in parallel to get genre tags
            await withTaskGroup(of: [String].self) { group in
                for key in albumKeysToCheck {
                    group.addTask {
                        guard let meta = try? await self.cachedMetadata(server: server, ratingKey: key) else { return [] }
                        return (meta.genre ?? []).compactMap(\.tag).filter { !$0.isEmpty }
                    }
                }
                for await genres in group {
                    for g in genres {
                        seedGenres.insert(g.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
            useGenreMatching = !seedGenres.isEmpty
        }

        let allTracks = try await cachedTracks(server: server, sectionId: sectionId)

        var matchingAlbumKeys = Set<String>()

        if !seedStyles.isEmpty {
            let normalizedSeed = Set(seedStyles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for (albumKey, styles) in stylesByAlbum {
                guard albumKey != seedAlbumKey else { continue }
                let normalized = Set(styles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                if normalizedSeed.intersection(normalized).count >= minMatchingStyles {
                    matchingAlbumKeys.insert(albumKey)
                }
            }
        } else if useGenreMatching {
            // Match albums by genre — fetch full metadata for each album is too expensive,
            // so check genre on the bulk list first, then fall back to albums that have styles
            // matching any genre keyword.
            for album in allAlbums {
                guard album.ratingKey != seedAlbumKey else { continue }
                let albumGenres = Set((album.genre ?? []).compactMap { $0.tag?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
                if !seedGenres.intersection(albumGenres).isEmpty {
                    matchingAlbumKeys.insert(album.ratingKey)
                }
            }
            // Also match albums whose style tags overlap with seed genres
            // (e.g., seed genre "Rock" matches album style "Rock")
            if matchingAlbumKeys.isEmpty {
                for (albumKey, styles) in stylesByAlbum {
                    guard albumKey != seedAlbumKey else { continue }
                    let normalized = Set(styles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                    if !seedGenres.intersection(normalized).isEmpty {
                        matchingAlbumKeys.insert(albumKey)
                    }
                }
            }
        }

        // Fallback 3: if no tag-based matches, use other tracks by the same artist
        if matchingAlbumKeys.isEmpty, let artistKey = seedArtistKey {
            let artistTracks = allTracks.filter {
                $0.grandparentRatingKey == artistKey && $0.parentRatingKey != seedAlbumKey
            }
            if !artistTracks.isEmpty {
                return Array(artistTracks.shuffled().prefix(limit))
            }
        }

        guard !matchingAlbumKeys.isEmpty else { return [] }

        var tracksByAlbum: [String: [PlexMetadata]] = [:]
        for track in allTracks {
            guard let albumKey = track.parentRatingKey,
                  matchingAlbumKeys.contains(albumKey) else { continue }
            tracksByAlbum[albumKey, default: []].append(track)
        }

        guard !tracksByAlbum.isEmpty else { return [] }

        let maxPerAlbum = 3
        var result: [PlexMetadata] = []
        var albumQueues = tracksByAlbum.values.map { $0.shuffled() }.shuffled()

        while result.count < limit && !albumQueues.isEmpty {
            var nextRound: [[PlexMetadata]] = []
            for var queue in albumQueues {
                let take = min(maxPerAlbum, queue.count, limit - result.count)
                result.append(contentsOf: queue.prefix(take))
                queue.removeFirst(take)
                if !queue.isEmpty && result.count < limit {
                    nextRound.append(queue)
                }
            }
            albumQueues = nextRound.shuffled()
        }

        return result.shuffled()
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
            group.addTask { ("tracks", (try? await self.cachedTracks(server: server, sectionId: sectionId)) ?? []) }
            group.addTask {
                _ = try? await self.cachedPlaylists(server: server)
                return ("playlists", [])
            }
            group.addTask { ("recent", (try? await self.getRecentlyPlayed(server: server, sectionId: sectionId, limit: 30)) ?? []) }
            group.addTask { ("favorites", (try? await self.getFavoriteTracks(server: server, sectionId: sectionId)) ?? []) }

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
        prefetchArtwork(for: artists + albums, server: server, size: 256)

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
                    _ = try? await self.cachedChildren(server: server, ratingKey: key)
                    _ = try? await self.cachedMetadata(server: server, ratingKey: key)
                    _ = try? await self.cachedTopTracks(server: server, sectionId: sectionId, artistRatingKey: key)
                }
            }
            for key in topAlbumKeys {
                group.addTask {
                    _ = try? await self.cachedChildren(server: server, ratingKey: key)
                    _ = try? await self.cachedMetadata(server: server, ratingKey: key)
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

        Task.detached(priority: .utility) {
            await ImageCache.shared.prefetch(urls: urls, targetPixelSize: size, maxConcurrent: 2)
        }
    }

    // MARK: - Private Helpers

    private func deduplicateTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)).inserted }
    }

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

    @discardableResult
    private func refreshAlbumStyles(server: PlexServer, sectionId: String, key: String) async throws -> [String: [String]] {
        let albums = try await cachedAlbums(server: server, sectionId: sectionId)
        var stylesByAlbum: [String: [String]] = [:]

        var missingStyleKeys: [String] = []
        for album in albums {
            let tags = (album.style ?? [])
                .compactMap(\.tag)
                .filter { !$0.isEmpty }
            if !tags.isEmpty {
                stylesByAlbum[album.ratingKey] = tags
            } else {
                missingStyleKeys.append(album.ratingKey)
            }
        }

        if !missingStyleKeys.isEmpty {
            let maxConcurrent = 10
            for batch in stride(from: 0, to: missingStyleKeys.count, by: maxConcurrent) {
                let batchKeys = Array(missingStyleKeys[batch..<min(batch + maxConcurrent, missingStyleKeys.count)])
                await withTaskGroup(of: (String, [String]).self) { group in
                    for albumKey in batchKeys {
                        group.addTask {
                            guard let details = try? await self.cachedMetadata(server: server, ratingKey: albumKey) else {
                                return (albumKey, [])
                            }
                            let tags = (details.style ?? [])
                                .compactMap(\.tag)
                                .filter { !$0.isEmpty }
                            return (albumKey, tags)
                        }
                    }
                    for await (albumKey, tags) in group {
                        if !tags.isEmpty {
                            stylesByAlbum[albumKey] = tags
                        }
                    }
                }
            }
        }

        await LibraryCache.shared.set(stylesByAlbum, forKey: key)
        return stylesByAlbum
    }
}
