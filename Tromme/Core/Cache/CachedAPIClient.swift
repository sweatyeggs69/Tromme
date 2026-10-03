import Foundation

/// Extension on PlexAPIClient providing local-first access to library data.
///
/// Artists, albums, tracks, album/artist children and metadata are read from the on-disk
/// `LibraryStore`, which `LibrarySyncService` keeps in sync in the background — browsing
/// never waits on the network once the library has been mirrored. Home rows (recently
/// added/played, favorites) are local queries over the same store; playlists and the
/// section list live in it too. The server is only asked for changes, via `smartRefresh`.
extension PlexAPIClient {

    // MARK: - Library Sections

    /// Served from disk; refreshed in the background so a newly added library shows up
    /// next time. Only the very first call (nothing stored yet) waits on the network.
    func cachedLibrarySections(server: PlexServer) async throws -> [LibrarySection] {
        let serverId = server.machineIdentifier
        if let stored = await LibraryStore.shared.sections(serverId: serverId) {
            Task(priority: .utility) {
                if let fresh = try? await self.getLibrarySections(server: server) {
                    await LibraryStore.shared.saveSections(fresh, serverId: serverId)
                }
            }
            return stored
        }
        let fresh = try await getLibrarySections(server: server)
        await LibraryStore.shared.saveSections(fresh, serverId: serverId)
        return fresh
    }

    // MARK: - Local Library Reads

    private func scope(_ server: PlexServer, _ sectionId: String) -> String {
        LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
    }

    /// Ensures `kind` has been mirrored (waiting on / starting the first sync if not).
    private func awaitLibrary(kind: Int, server: PlexServer, sectionId: String) async throws {
        try await LibrarySyncService.shared.waitUntilReady(kind: kind, client: self, server: server, sectionId: sectionId)
    }

    private func localItems(kind: Int, server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        try await awaitLibrary(kind: kind, server: server, sectionId: sectionId)
        return await LibraryStore.shared.items(kind: kind, scope: scope(server, sectionId))
    }

    // MARK: - Artists / Albums / Tracks

    func cachedArtists(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        try await localItems(kind: LibraryStore.Kind.artist, server: server, sectionId: sectionId)
    }

    func cachedAlbums(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        try await localItems(kind: LibraryStore.Kind.album, server: server, sectionId: sectionId)
    }

    func cachedTracks(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        try await localItems(kind: LibraryStore.Kind.track, server: server, sectionId: sectionId)
    }

    func cachedArtistReleases(server: PlexServer, sectionId: String, artist: PlexMetadata) async throws -> [PlexMetadata] {
        var releases = try await cachedChildren(server: server, ratingKey: artist.ratingKey, sectionId: sectionId)
        let releaseKeys = Set(releases.map(\.ratingKey))
        let artistTracks = try await cachedArtistTracks(server: server, sectionId: sectionId, artist: artist)
        let missingReleaseKeys = Set(artistTracks.compactMap(\.parentRatingKey)).subtracting(releaseKeys)

        // Albums credited to another album-artist but containing this artist's tracks.
        for key in missingReleaseKeys {
            if let release = await LibraryStore.shared.item(ratingKey: key, serverId: server.machineIdentifier) {
                releases.append(release)
            }
        }

        var seenKeys = Set<String>()
        return releases
            .filter { seenKeys.insert($0.ratingKey).inserted }
            .sorted(by: releaseSort)
    }

    func cachedArtistTracks(server: PlexServer, sectionId: String, artist: PlexMetadata) async throws -> [PlexMetadata] {
        try await awaitLibrary(kind: LibraryStore.Kind.track, server: server, sectionId: sectionId)
        return await LibraryStore.shared.tracks(byArtist: artist.ratingKey, scope: scope(server, sectionId))
    }

    // MARK: - Favorites

    /// Matches the threshold of `getFavoriteTracks` so local and server results agree.
    private static let favoriteMinRating: Double = 4

    /// Local query once tracks are mirrored; until then (first launch) one network fetch.
    func cachedFavoriteTracks(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        let scope = scope(server, sectionId)
        if await LibraryStore.shared.isReady(kind: LibraryStore.Kind.track, scope: scope) {
            return await LibraryStore.shared.favorites(scope: scope, minUserRating: Self.favoriteMinRating)
        }
        return try await getFavoriteTracks(server: server, sectionId: sectionId)
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

    /// Tracks credited to `artistTitle` via track-level artist credit (`originalTitle`), on
    /// albums whose primary artist is someone else — e.g. various-artist compilation tracks.
    private func compilationCreditedTracks(server: PlexServer, sectionId: String, artistRatingKey: String, artistTitle: String) async throws -> [PlexMetadata] {
        let allTracks = try await cachedTracks(server: server, sectionId: sectionId)
        let artistTitleLower = artistTitle.lowercased()
        return allTracks.filter { track in
            guard track.grandparentRatingKey != artistRatingKey else { return false }
            guard let credit = track.originalTitle?.lowercased(), !credit.isEmpty else { return false }
            return credit.contains(artistTitleLower)
        }
    }

    /// Albums where the given artist is credited as a featured performer but is not the primary artist.
    func appearsOnAlbums(server: PlexServer, sectionId: String, artistRatingKey: String, artistTitle: String) async throws -> [PlexMetadata] {
        let featured = try await compilationCreditedTracks(server: server, sectionId: sectionId, artistRatingKey: artistRatingKey, artistTitle: artistTitle)
        let featuredAlbumKeys = Set(featured.compactMap(\.parentRatingKey))
        guard !featuredAlbumKeys.isEmpty else { return [] }

        let allAlbums = try await cachedAlbums(server: server, sectionId: sectionId)
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

    /// All tracks performed by this artist: their own discography plus any compilation
    /// (various-artist album) appearances credited via track-level artist credit.
    func allArtistTracks(server: PlexServer, sectionId: String, artist: PlexMetadata) async throws -> [PlexMetadata] {
        async let ownTracksReq = cachedArtistTracks(server: server, sectionId: sectionId, artist: artist)
        async let compilationTracksReq = compilationCreditedTracks(server: server, sectionId: sectionId, artistRatingKey: artist.ratingKey, artistTitle: artist.title)

        let ownTracks = try await ownTracksReq
        let compilationTracks = (try? await compilationTracksReq) ?? []

        var seenKeys = Set<String>()
        return (ownTracks + compilationTracks).filter { seenKeys.insert($0.ratingKey).inserted }
    }

    // MARK: - Recently Played / Recently Added

    func cachedRecentlyPlayed(server: PlexServer, sectionId: String, limit: Int = 10) async throws -> [PlexMetadata] {
        let scope = scope(server, sectionId)
        if await LibraryStore.shared.isReady(kind: LibraryStore.Kind.track, scope: scope) {
            return await LibraryStore.shared.recentlyPlayed(scope: scope, limit: limit)
        }
        return try await getRecentlyPlayed(server: server, sectionId: sectionId, limit: limit)
    }

    func cachedRecentlyAdded(server: PlexServer, sectionId: String, limit: Int = 10) async throws -> [PlexMetadata] {
        let scope = scope(server, sectionId)
        if await LibraryStore.shared.isReady(kind: LibraryStore.Kind.album, scope: scope) {
            return await LibraryStore.shared.recentlyAdded(scope: scope, limit: limit)
        }
        return try await getRecentlyAdded(server: server, sectionId: sectionId, type: 9, limit: limit)
    }

    // MARK: - Children (albums for artist, tracks for album)

    /// Local lookup by parent key. If the library hasn't mirrored the item yet (first sync
    /// still running, or an item added since the last sync) it falls back to one network
    /// fetch so the screen is never empty. `updatedAt` is accepted for source compatibility;
    /// the store is kept current by the sync, so it no longer versions anything.
    func cachedChildren(server: PlexServer, ratingKey: String, updatedAt: Int? = nil, sectionId: String? = nil) async throws -> [PlexMetadata] {
        let serverId = server.machineIdentifier
        let resolvedSection: String?
        if let sectionId {
            resolvedSection = sectionId
        } else {
            resolvedSection = await LibraryStore.shared.sectionId(ofRatingKey: ratingKey, serverId: serverId)
        }
        guard let resolvedSection else {
            return try await getMetadataChildren(server: server, ratingKey: ratingKey)
        }

        let scope = scope(server, resolvedSection)
        var items = await LibraryStore.shared.children(of: ratingKey, scope: scope)
        if items.isEmpty {
            try? await awaitLibrary(kind: LibraryStore.Kind.track, server: server, sectionId: resolvedSection)
            items = await LibraryStore.shared.children(of: ratingKey, scope: scope)
        }
        if items.isEmpty {
            return try await getMetadataChildren(server: server, ratingKey: ratingKey)
        }
        return items
    }

    // MARK: - Playlists

    /// Playlist keys arrive as a ratingKey or as a `/playlists/{id}/items` path.
    static func playlistRatingKey(from key: String) -> String {
        guard key.hasPrefix("/playlists/") else { return key }
        return key.split(separator: "/").dropFirst().first.map(String.init) ?? key
    }

    func cachedPlaylists(server: PlexServer) async throws -> [PlexPlaylist] {
        let serverId = server.machineIdentifier
        if !(await LibraryStore.shared.playlistsSynced(serverId: serverId)) {
            try await refreshPlaylists(server: server)
        }
        return await LibraryStore.shared.playlists(serverId: serverId)
    }

    func cachedPlaylistItems(server: PlexServer, playlistKey: String) async throws -> [PlexMetadata] {
        let serverId = server.machineIdentifier
        let key = Self.playlistRatingKey(from: playlistKey)
        if let stored = await LibraryStore.shared.playlistItems(playlistKey: key, serverId: serverId) {
            return stored
        }
        let items = try await getPlaylistItems(server: server, playlistKey: playlistKey)
        await LibraryStore.shared.savePlaylistItems(items, playlistKey: key, serverId: serverId)
        return items
    }

    /// Mirrors the playlist list and the items of any playlist that is new or changed.
    /// Coalesced: concurrent callers share one refresh.
    func refreshPlaylists(server: PlexServer) async throws {
        try await LibrarySyncService.shared.refreshPlaylists(client: self, server: server)
    }

    /// The uncoalesced work behind `refreshPlaylists` — call that instead.
    func performPlaylistRefresh(server: PlexServer) async throws {
        let serverId = server.machineIdentifier
        let fresh = try await getPlaylists(server: server)
        await LibraryStore.shared.savePlaylists(fresh, serverId: serverId)

        let musicKeys = Set(fresh.filter(\.isMusicPlaylist).map(\.ratingKey))
        let stale = await LibraryStore.shared.playlistKeysNeedingItems(serverId: serverId).filter(musicKeys.contains)

        await withTaskGroup(of: Void.self) { group in
            var iterator = stale.makeIterator()
            func addNext() {
                guard let key = iterator.next() else { return }
                group.addTask {
                    guard let items = try? await self.getPlaylistItems(server: server, playlistKey: key) else { return }
                    await LibraryStore.shared.savePlaylistItems(items, playlistKey: key, serverId: serverId)
                }
            }
            for _ in 0..<3 { addNext() }
            while await group.next() != nil { addNext() }
        }
        NotificationCenter.default.post(name: .libraryContentDidChange, object: nil)
    }

    /// Re-reads one playlist (listing + items) after the user changed it.
    func refreshPlaylist(server: PlexServer, playlistKey: String) async {
        let serverId = server.machineIdentifier
        let key = Self.playlistRatingKey(from: playlistKey)
        guard let fresh = try? await getPlaylists(server: server) else { return }
        await LibraryStore.shared.savePlaylists(fresh, serverId: serverId)
        if fresh.contains(where: { $0.ratingKey == key }),
           let items = try? await getPlaylistItems(server: server, playlistKey: key) {
            await LibraryStore.shared.savePlaylistItems(items, playlistKey: key, serverId: serverId)
        } else {
            await LibraryStore.shared.removePlaylist(playlistKey: key, serverId: serverId)
        }
        NotificationCenter.default.post(name: .libraryContentDidChange, object: nil)
    }

    // MARK: - Metadata (single item)

    /// Detail metadata for one item. Served from disk while it's current for the item's
    /// `updatedAt` (artist details are pre-fetched by the library sync); otherwise fetched
    /// once and persisted. Offline, falls back to whatever is stored.
    func cachedMetadata(server: PlexServer, ratingKey: String) async throws -> PlexMetadata? {
        let serverId = server.machineIdentifier
        if let fresh = await LibraryStore.shared.freshDetail(ratingKey: ratingKey, serverId: serverId) {
            return fresh
        }
        do {
            let fetched = try await getMetadata(server: server, ratingKey: ratingKey)
            if let fetched { await LibraryStore.shared.saveDetail(fetched, serverId: serverId) }
            return fetched
        } catch {
            if let stored = await LibraryStore.shared.anyMetadata(ratingKey: ratingKey, serverId: serverId) {
                return stored
            }
            throw error
        }
    }

    func cachedAlbumMetadata(server: PlexServer, ratingKey: String) async throws -> PlexMetadata? {
        try await cachedMetadata(server: server, ratingKey: ratingKey)
    }

    // MARK: - Refresh

    /// Cold-launch / foreground / pull-to-refresh entry point: brings the local library up
    /// to date if the server's section changed, and pulls changed user state and playlists.
    func smartRefresh(server: PlexServer, sectionId: String, forceLibrarySync: Bool = false) async {
        async let dynamic: Void = refreshDynamicContent(server: server, sectionId: sectionId)
        await LibrarySyncService.shared.refreshIfNeeded(client: self, server: server, sectionId: sectionId, force: forceLibrarySync)
        await dynamic
    }

    /// The fast, frequently-changing part of a refresh: play counts / ratings (which drive
    /// Home's recently played and favorites) and playlists.
    func refreshDynamicContent(server: PlexServer, sectionId: String) async {
        async let playlists: Void = { try? await refreshPlaylists(server: server) }()
        await refreshUserState(server: server, sectionId: sectionId)
        await playlists
    }

    /// Fetches recently played and favorited tracks and writes their fresh play counts and
    /// ratings into the store. Tracks that were favorited locally but no longer are on the
    /// server are re-read by id (batched) so un-favorites propagate too.
    func refreshUserState(server: PlexServer, sectionId: String) async {
        let scope = scope(server, sectionId)
        guard await LibraryStore.shared.isReady(kind: LibraryStore.Kind.track, scope: scope) else { return }

        async let recentRequest = try? getRecentlyPlayed(server: server, sectionId: sectionId, limit: 50)
        async let favoritesRequest = try? getFavoriteTracks(server: server, sectionId: sectionId)
        let (recent, favorites) = await (recentRequest, favoritesRequest)

        var updates = recent ?? []
        if let favorites {
            updates += favorites
            let stale = await LibraryStore.shared.favoriteKeys(scope: scope, minUserRating: Self.favoriteMinRating)
                .subtracting(favorites.map(\.ratingKey))
            updates += await fetchMetadata(server: server, ratingKeys: Array(stale))
        }
        guard !updates.isEmpty else { return }
        await LibraryStore.shared.applyTrackUpdates(updates, scope: scope)
        NotificationCenter.default.post(name: .libraryContentDidChange, object: nil)
    }

    /// Re-reads one track after the user rated or played it, so Home and Favorites update
    /// from the store immediately.
    func refreshItem(server: PlexServer, ratingKey: String) async {
        guard let sectionId = await LibraryStore.shared.sectionId(ofRatingKey: ratingKey, serverId: server.machineIdentifier),
              let fresh = try? await getMetadata(server: server, ratingKey: ratingKey) else { return }
        await LibraryStore.shared.applyTrackUpdates([fresh], scope: scope(server, sectionId))
    }

    /// `/library/metadata/{ids}` accepts a comma-separated list, so many items cost one request.
    func fetchMetadata(server: PlexServer, ratingKeys: [String], batchSize: Int = 50) async -> [PlexMetadata] {
        var result: [PlexMetadata] = []
        for start in stride(from: 0, to: ratingKeys.count, by: batchSize) {
            let batch = Array(ratingKeys[start..<min(start + batchSize, ratingKeys.count)])
            if let items = try? await getMetadata(server: server, ratingKeys: batch) { result += items }
        }
        return result
    }

    // MARK: - Artwork Prefetching

    /// Build artwork URLs for metadata items and prefetch them into the image cache.
    /// Fires in the background so it doesn't block the caller.
    ///
    /// Capped at `maxPrefetchItems` — this fires from `cachedLibraryContents` on every
    /// artist/album list load, including a full cold sweep right after Refresh Library
    /// clears the image cache. Without a cap it queued a full-resolution download for
    /// every artist and album in the whole library, starving the small on-screen thumbnail
    /// requests that share the same download session and making artwork crawl in.
    /// The rest of the library still loads lazily as each screen's own windowed prefetch
    /// (e.g. ArtistsView.prefetchVisibleArtwork) or on-demand ArtworkView requests run.
    func prefetchArtwork(for items: [PlexMetadata], server: PlexServer, size: Int = 256) {
        guard NetworkStatus.shared.isConnected,
              !NetworkStatus.shared.isExpensive,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let maxPrefetchItems = 150
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
            await ImageCache.shared.prefetch(urls: urls, targetPixelSize: size, maxConcurrent: 4)
        }
    }

    // MARK: - Private Helpers

    private func releaseSort(_ lhs: PlexMetadata, _ rhs: PlexMetadata) -> Bool {
        let leftDate = lhs.originallyAvailableAt ?? ""
        let rightDate = rhs.originallyAvailableAt ?? ""
        if leftDate != rightDate { return leftDate > rightDate }
        if (lhs.year ?? 0) != (rhs.year ?? 0) { return (lhs.year ?? 0) > (rhs.year ?? 0) }
        return (lhs.titleSort ?? lhs.title) < (rhs.titleSort ?? rhs.title)
    }

}
