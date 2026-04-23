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
        seedTrackKey: String? = nil,
        seedAlbumKey: String,
        seedArtistKey: String? = nil,
        limit: Int = 25,
        minMatchingStyles: Int = 1
    ) async throws -> [PlexMetadata] {
        guard limit > 0, minMatchingStyles > 0 else { return [] }
        #if DEBUG
        func debugMixLog(_ message: String) {
            print("[MagicMix] \(message)")
        }
        #endif

        let metadataTags: (PlexMetadata) -> [String] = { metadata in
            (metadata.style ?? [])
                .compactMap(\.tag)
                .filter { !$0.isEmpty }
        }

        let seedTrackMetadata: PlexMetadata? = if let seedTrackKey {
            try? await cachedMetadata(server: server, ratingKey: seedTrackKey)
        } else {
            nil
        }

        var resolvedSeedArtistKey = seedArtistKey
        if resolvedSeedArtistKey == nil {
            resolvedSeedArtistKey = seedTrackMetadata?.grandparentRatingKey
        }
        if resolvedSeedArtistKey == nil {
            resolvedSeedArtistKey = (try? await cachedMetadata(server: server, ratingKey: seedAlbumKey))?.parentRatingKey
        }
        if resolvedSeedArtistKey == nil {
            resolvedSeedArtistKey = (try? await getMetadata(server: server, ratingKey: seedAlbumKey))?.parentRatingKey
        }

        let stylesByAlbum = try await cachedAlbumStyles(server: server, sectionId: sectionId)
        let allAlbums = try await cachedAlbums(server: server, sectionId: sectionId)
        let allAlbumsByKey = Dictionary(uniqueKeysWithValues: allAlbums.map { ($0.ratingKey, $0) })

        var seedStyles = (seedTrackMetadata?.style ?? [])
            .compactMap(\.tag)
            .filter { !$0.isEmpty }
        seedStyles = deduplicateTags(seedStyles)
        var seedTagSource = seedStyles.isEmpty ? "none" : "track"

        // Fallback 1: use the current track's album style tags.
        if seedStyles.isEmpty, let albumStyles = stylesByAlbum[seedAlbumKey], !albumStyles.isEmpty {
            seedStyles = deduplicateTags(albumStyles)
            seedTagSource = "seed_album_cache"
        }
        if seedStyles.isEmpty {
            if let albumMetadata = try? await getMetadata(server: server, ratingKey: seedAlbumKey) {
                seedStyles = deduplicateTags(metadataTags(albumMetadata))
                if !seedStyles.isEmpty { seedTagSource = "seed_album_metadata" }
            } else if let albumMetadata = try? await cachedMetadata(server: server, ratingKey: seedAlbumKey) {
                seedStyles = deduplicateTags(metadataTags(albumMetadata))
                if !seedStyles.isEmpty { seedTagSource = "seed_album_cached_metadata" }
            }
        }

        // Fallback 2: borrow styles from sibling albums by the same artist.
        if seedStyles.isEmpty, let artistKey = resolvedSeedArtistKey {
            let siblings = (try? await cachedChildren(server: server, ratingKey: artistKey)) ?? []
            for album in siblings where album.ratingKey != seedAlbumKey {
                if let styles = stylesByAlbum[album.ratingKey], !styles.isEmpty {
                    seedStyles.append(contentsOf: styles)
                    continue
                }
                if let albumMetadata = try? await getMetadata(server: server, ratingKey: album.ratingKey) {
                    seedStyles.append(contentsOf: metadataTags(albumMetadata))
                }
            }
            seedStyles = deduplicateTags(seedStyles)
            if !seedStyles.isEmpty { seedTagSource = "sibling_albums" }
        }

        // Fallback 3: if still no styles, match by artist genre.
        var useGenreMatching = false
        var seedGenres = Set<String>()
        if seedStyles.isEmpty,
           let artistKey = resolvedSeedArtistKey,
           let artist = try? await cachedMetadata(server: server, ratingKey: artistKey) {
            let genres = (artist.genre ?? []).compactMap(\.tag)
            for genre in genres {
                let normalized = genre.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    seedGenres.insert(normalized)
                }
            }
            useGenreMatching = !seedGenres.isEmpty
        }
        #if DEBUG
        debugMixLog("seedSource=\(seedTagSource) seedTagCount=\(seedStyles.count) genreFallback=\(useGenreMatching)")
        #endif

        let allTracks = try await cachedTracks(server: server, sectionId: sectionId)

        var matchingAlbumKeys = Set<String>()
        let isSameArtistAlbum: (String) -> Bool = { albumKey in
            guard let artistKey = resolvedSeedArtistKey else { return false }
            return allAlbumsByKey[albumKey]?.parentRatingKey == artistKey
        }
        let effectiveMinMatchingStyles = max(1, min(minMatchingStyles, seedStyles.count))

        if !seedStyles.isEmpty {
            let normalizedSeed = Set(seedStyles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for (albumKey, styles) in stylesByAlbum {
                guard albumKey != seedAlbumKey else { continue }
                guard !isSameArtistAlbum(albumKey) else { continue }
                let normalized = Set(styles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                if normalizedSeed.intersection(normalized).count >= effectiveMinMatchingStyles {
                    matchingAlbumKeys.insert(albumKey)
                }
            }
            #if DEBUG
            debugMixLog("matchMode=style matchedAlbums=\(matchingAlbumKeys.count) requiredMatches=\(effectiveMinMatchingStyles) configuredMin=\(minMatchingStyles)")
            #endif
        } else if useGenreMatching {
            // Match albums by genre — fetch full metadata for each album is too expensive,
            // so check genre on the bulk list first, then fall back to albums that have styles
            // matching any genre keyword.
            for album in allAlbums {
                guard album.ratingKey != seedAlbumKey else { continue }
                guard !isSameArtistAlbum(album.ratingKey) else { continue }
                let albumGenres = Set((album.genre ?? []).compactMap { $0.tag?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
                if !seedGenres.intersection(albumGenres).isEmpty {
                    matchingAlbumKeys.insert(album.ratingKey)
                }
            }
            // Also match albums whose style tags overlap with seed genres.
            if matchingAlbumKeys.isEmpty {
                for (albumKey, styles) in stylesByAlbum {
                    guard albumKey != seedAlbumKey else { continue }
                    guard !isSameArtistAlbum(albumKey) else { continue }
                    let normalized = Set(styles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                    if !seedGenres.intersection(normalized).isEmpty {
                        matchingAlbumKeys.insert(albumKey)
                    }
                }
            }
            #if DEBUG
            debugMixLog("matchMode=genre matchedAlbums=\(matchingAlbumKeys.count)")
            #endif
        }

        // Fallback 4: if no tag-based matches, use other tracks by the same artist
        if matchingAlbumKeys.isEmpty, let artistKey = resolvedSeedArtistKey {
            // Prefer sibling albums as the fallback source, since parentRatingKey is more
            // reliable in bulk track payloads than grandparentRatingKey.
            let siblingAlbums = (try? await cachedChildren(server: server, ratingKey: artistKey)) ?? []
            let siblingAlbumKeys = Set(
                siblingAlbums
                    .map(\.ratingKey)
                    .filter { $0 != seedAlbumKey }
            )

            if !siblingAlbumKeys.isEmpty {
                let siblingAlbumTracks = allTracks.filter {
                    guard let parentKey = $0.parentRatingKey else { return false }
                    return siblingAlbumKeys.contains(parentKey)
                }
                if !siblingAlbumTracks.isEmpty {
                    #if DEBUG
                    debugMixLog("finalFallback=sibling_artist_tracks resultCount=\(min(limit, siblingAlbumTracks.count))")
                    #endif
                    return Array(siblingAlbumTracks.shuffled().prefix(limit))
                }
            }

            // Secondary fallback when album linkage is unavailable.
            let artistTracks = allTracks.filter {
                $0.grandparentRatingKey == artistKey && $0.parentRatingKey != seedAlbumKey
            }
            if !artistTracks.isEmpty {
                #if DEBUG
                debugMixLog("finalFallback=artist_tracks resultCount=\(min(limit, artistTracks.count))")
                #endif
                return Array(artistTracks.shuffled().prefix(limit))
            }
        }

        guard !matchingAlbumKeys.isEmpty else {
            #if DEBUG
            debugMixLog("result=empty reason=no_matches")
            #endif
            return []
        }

        var tracksByAlbum: [String: [PlexMetadata]] = [:]
        for track in allTracks {
            guard let albumKey = track.parentRatingKey,
                  matchingAlbumKeys.contains(albumKey) else { continue }
            tracksByAlbum[albumKey, default: []].append(track)
        }

        guard !tracksByAlbum.isEmpty else { return [] }

        let maxPerAlbum = 3
        var picked: [PlexMetadata] = []
        var albumQueues = tracksByAlbum.values.map { $0.shuffled() }.shuffled()

        while picked.count < limit && !albumQueues.isEmpty {
            var nextRound: [[PlexMetadata]] = []
            for var queue in albumQueues {
                let take = min(maxPerAlbum, queue.count, limit - picked.count)
                picked.append(contentsOf: queue.prefix(take))
                queue.removeFirst(take)
                if !queue.isEmpty && picked.count < limit {
                    nextRound.append(queue)
                }
            }
            albumQueues = nextRound.shuffled()
        }

        #if DEBUG
        debugMixLog("result=tag_match_tracks count=\(min(limit, picked.count))")
        #endif
        return interleaveTracksAvoidingAdjacentAlbums(picked, limit: limit)
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

        Task(priority: .utility) {
            await ImageCache.shared.prefetch(urls: urls, targetPixelSize: size, maxConcurrent: 2)
        }
    }

    // MARK: - Private Helpers

    private func deduplicateTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)).inserted }
    }

    private func interleaveTracksAvoidingAdjacentAlbums(_ tracks: [PlexMetadata], limit: Int) -> [PlexMetadata] {
        guard !tracks.isEmpty, limit > 0 else { return [] }

        var byAlbum: [String: [PlexMetadata]] = [:]
        let fallbackAlbumKey = "__unknown_album__"
        for track in tracks {
            let albumKey = track.parentRatingKey ?? fallbackAlbumKey
            byAlbum[albumKey, default: []].append(track)
        }
        for key in byAlbum.keys {
            byAlbum[key]?.shuffle()
        }

        var result: [PlexMetadata] = []
        result.reserveCapacity(min(limit, tracks.count))
        var lastAlbumKey: String?

        while result.count < limit {
            var candidateKey: String?
            var candidateCount = -1

            for (albumKey, albumTracks) in byAlbum where !albumTracks.isEmpty {
                if albumKey == lastAlbumKey { continue }
                if albumTracks.count > candidateCount {
                    candidateKey = albumKey
                    candidateCount = albumTracks.count
                }
            }

            if candidateKey == nil {
                candidateKey = byAlbum.first(where: { !$0.value.isEmpty })?.key
            }
            guard let selectedAlbumKey = candidateKey,
                  var selectedAlbumTracks = byAlbum[selectedAlbumKey],
                  !selectedAlbumTracks.isEmpty else { break }

            let next = selectedAlbumTracks.removeFirst()
            byAlbum[selectedAlbumKey] = selectedAlbumTracks
            result.append(next)
            lastAlbumKey = selectedAlbumKey
        }

        return result
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
