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
        if !NetworkStatus.shared.isExpensive, !ProcessInfo.processInfo.isLowPowerModeEnabled {
            Task { try? await cachedAlbumStyles(server: server, sectionId: sectionId) }
        }
        return albums
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

    func recommendedAlbums(
        server: PlexServer,
        sectionId: String,
        seedAlbum: PlexMetadata,
        seedArtistKey: String?,
        minMatchingStyles: Int
    ) async throws -> [PlexMetadata] {
        guard minMatchingStyles > 0 else { return [] }

        let stylesByAlbum = try await cachedAlbumStyles(server: server, sectionId: sectionId)
        let allAlbums = try await cachedAlbums(server: server, sectionId: sectionId)
        let allAlbumsByKey = Dictionary(uniqueKeysWithValues: allAlbums.map { ($0.ratingKey, $0) })

        var seedStyles = stylesByAlbum[seedAlbum.ratingKey] ?? []
        if seedStyles.isEmpty {
            let seedDetails = try await cachedAlbumMetadata(server: server, ratingKey: seedAlbum.ratingKey)
            seedStyles = metadataTags(seedDetails ?? seedAlbum)
        }
        seedStyles = deduplicateTags(seedStyles)
        guard !seedStyles.isEmpty else { return [] }

        let effectiveMinMatchingStyles = max(1, min(minMatchingStyles, seedStyles.count))

        var scoredAlbums: [(album: PlexMetadata, score: Int)] = []
        for (albumKey, styles) in stylesByAlbum {
            guard albumKey != seedAlbum.ratingKey else { continue }
            if let seedArtistKey, allAlbumsByKey[albumKey]?.parentRatingKey == seedArtistKey {
                continue
            }

            let score = styleMatchScore(seed: seedStyles, candidate: styles)
            guard score >= effectiveMinMatchingStyles, let album = allAlbumsByKey[albumKey] else { continue }
            scoredAlbums.append((album: album, score: score))
        }

        return scoredAlbums
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return releaseSort($0.album, $1.album)
            }
            .map(\.album)
    }

    // MARK: - Cached Album Styles

    func cachedAlbumStyles(server: PlexServer, sectionId: String) async throws -> [String: [String]] {
        try await LibraryCache.shared.cachedFetch(
            forKey: CacheKey.albumStyles(serverId: server.machineIdentifier, sectionId: sectionId),
            policy: .styles
        ) {
            try await self.refreshAlbumStyles(server: server, sectionId: sectionId)
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

    /// Artists in the library whose album styles overlap with the seed artist's album styles.
    /// Uses the same cached style index as `recommendedAlbums`.
    func similarArtists(server: PlexServer, sectionId: String, seedArtistKey: String) async throws -> [PlexMetadata] {
        let allArtists = try await cachedArtists(server: server, sectionId: sectionId)
        let allAlbums = try await cachedAlbums(server: server, sectionId: sectionId)
        let stylesByAlbum = try await cachedAlbumStyles(server: server, sectionId: sectionId)

        // Build deduplicated raw-tag arrays per artist so styleMatchScore can apply
        // both exact and word-level matching (e.g. "Hardcore Rap" ~ "Contemporary Rap").
        var stylesByArtist: [String: [String]] = [:]
        for album in allAlbums {
            guard let artistKey = album.parentRatingKey else { continue }
            stylesByArtist[artistKey, default: []] += stylesByAlbum[album.ratingKey] ?? []
        }
        for key in stylesByArtist.keys {
            stylesByArtist[key] = deduplicateTags(stylesByArtist[key] ?? [])
        }

        let seedStyles = stylesByArtist[seedArtistKey] ?? []
        guard !seedStyles.isEmpty else { return [] }

        let artistByKey = Dictionary(uniqueKeysWithValues: allArtists.map { ($0.ratingKey, $0) })
        var scored: [(artist: PlexMetadata, score: Int)] = []
        for (artistKey, styles) in stylesByArtist {
            guard artistKey != seedArtistKey, let artist = artistByKey[artistKey] else { continue }
            let intersectionCount = styleMatchScore(seed: seedStyles, candidate: styles)
            guard intersectionCount >= 2 else { continue }
            // Approximate Jaccard: |A ∪ B| ≈ |A| + |B| - |A ∩ B|
            let unionCount = seedStyles.count + styles.count - intersectionCount
            let jaccard = Double(intersectionCount) / Double(max(1, unionCount))
            guard jaccard >= 0.30 else { continue }
            scored.append((artist: artist, score: intersectionCount))
        }

        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.artist.titleSort ?? $0.artist.title) < ($1.artist.titleSort ?? $1.artist.title)
            }
            .map(\.artist)
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

    /// Returns the significant words of a multi-word style tag for word-level matching.
    /// Single-word styles (e.g. "Pop", "Jazz") return an empty set so they can only
    /// exact-match — this prevents "Pop" from spuriously matching "Pop Punk".
    private func styleMatchWords(_ tag: String) -> Set<String> {
        let words = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 2 }
        guard words.count >= 2 else { return [] }
        return Set(words)
    }

    /// Counts how many seed styles have at least one match in the candidate list.
    /// A match is either an exact (case-insensitive) hit, or a word-level hit where
    /// both styles are multi-word compounds sharing at least one significant word.
    private func styleMatchScore(seed: [String], candidate: [String]) -> Int {
        let normalizedCandidate = Set(candidate.map(normalizedTag))
        let candidateWords = Set(candidate.flatMap { styleMatchWords($0) })
        var count = 0
        for seedStyle in seed {
            if normalizedCandidate.contains(normalizedTag(seedStyle)) {
                count += 1
                continue
            }
            let seedWords = styleMatchWords(seedStyle)
            if !seedWords.isEmpty && !candidateWords.isEmpty && !seedWords.isDisjoint(with: candidateWords) {
                count += 1
            }
        }
        return count
    }

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

    private func metadataTags(_ metadata: PlexMetadata) -> [String] {
        (metadata.style ?? [])
            .compactMap(\.tag)
            .filter { !$0.isEmpty }
    }

    private func normalizedTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func releaseSort(_ lhs: PlexMetadata, _ rhs: PlexMetadata) -> Bool {
        let leftDate = lhs.originallyAvailableAt ?? ""
        let rightDate = rhs.originallyAvailableAt ?? ""
        if leftDate != rightDate { return leftDate > rightDate }
        if (lhs.year ?? 0) != (rhs.year ?? 0) { return (lhs.year ?? 0) > (rhs.year ?? 0) }
        return (lhs.titleSort ?? lhs.title) < (rhs.titleSort ?? rhs.title)
    }

    @discardableResult
    private func refreshAlbumStyles(server: PlexServer, sectionId: String) async throws -> [String: [String]] {
        let albums = try await cachedAlbums(server: server, sectionId: sectionId)
        var stylesByAlbum: [String: [String]] = [:]

        var missingStyleKeys: [String] = []
        for album in albums {
            let tags = (album.style ?? []).compactMap(\.tag).filter { !$0.isEmpty }
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
                            let tags = (details.style ?? []).compactMap(\.tag).filter { !$0.isEmpty }
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

        return stylesByAlbum
    }
}
