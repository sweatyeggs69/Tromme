import Foundation

/// Extension on PlexAPIClient providing cache-first access to library data.
/// Pattern: return cached data immediately if available. If stale or missing,
/// fetch from network and update cache. Views get instant UI from cache
/// and seamless background refresh.
extension PlexAPIClient {

    // MARK: - Cached Library Sections

    func cachedLibrarySections(server: PlexServer) async throws -> [LibrarySection] {
        let key = CacheKey.sections(serverId: server.machineIdentifier)

        if let cached = await LibraryCache.shared.get([LibrarySection].self, forKey: key) {
            if !cached.isStale { return cached.value }
            // Return stale data but refresh in background
            Task { try? await refreshLibrarySections(server: server, key: key) }
            return cached.value
        }

        return try await refreshLibrarySections(server: server, key: key)
    }

    @discardableResult
    private func refreshLibrarySections(server: PlexServer, key: String) async throws -> [LibrarySection] {
        let sections = try await getLibrarySections(server: server)
        await LibraryCache.shared.set(sections, forKey: key)
        return sections
    }

    // MARK: - Cached Artists

    func cachedArtists(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        let key = CacheKey.artists(serverId: server.machineIdentifier, sectionId: sectionId)
        return try await cachedLibraryContents(server: server, sectionId: sectionId, type: 8, key: key)
    }

    // MARK: - Cached Albums

    func cachedAlbums(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        let key = CacheKey.albums(serverId: server.machineIdentifier, sectionId: sectionId)
        return try await cachedLibraryContents(server: server, sectionId: sectionId, type: 9, key: key)
    }

    // MARK: - Cached Tracks

    func cachedTracks(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        let key = CacheKey.tracks(serverId: server.machineIdentifier, sectionId: sectionId)
        return try await cachedLibraryContents(server: server, sectionId: sectionId, type: 10, key: key)
    }

    // MARK: - Cached Children (albums for artist, tracks for album)

    func cachedChildren(server: PlexServer, ratingKey: String) async throws -> [PlexMetadata] {
        let key = CacheKey.children(ratingKey: ratingKey)

        if let cached = await LibraryCache.shared.get([PlexMetadata].self, forKey: key) {
            if !cached.isStale { return cached.value }
            Task { try? await refreshChildren(server: server, ratingKey: ratingKey, key: key) }
            return cached.value
        }

        return try await refreshChildren(server: server, ratingKey: ratingKey, key: key)
    }

    @discardableResult
    private func refreshChildren(server: PlexServer, ratingKey: String, key: String) async throws -> [PlexMetadata] {
        let items = try await getMetadataChildren(server: server, ratingKey: ratingKey)
        await LibraryCache.shared.set(items, forKey: key)
        return items
    }

    // MARK: - Cached Playlists

    func cachedPlaylists(server: PlexServer) async throws -> [PlexPlaylist] {
        let key = CacheKey.playlists(serverId: server.machineIdentifier)

        if let cached = await LibraryCache.shared.get([PlexPlaylist].self, forKey: key) {
            if !cached.isStale { return cached.value }
            Task { try? await refreshPlaylists(server: server, key: key) }
            return cached.value
        }

        return try await refreshPlaylists(server: server, key: key)
    }

    @discardableResult
    private func refreshPlaylists(server: PlexServer, key: String) async throws -> [PlexPlaylist] {
        let playlists = try await getPlaylists(server: server)
        await LibraryCache.shared.set(playlists, forKey: key)
        return playlists
    }

    // MARK: - Cached Playlist Items

    func cachedPlaylistItems(server: PlexServer, playlistKey: String) async throws -> [PlexMetadata] {
        let key = CacheKey.playlistItems(playlistKey: playlistKey)

        if let cached = await LibraryCache.shared.get([PlexMetadata].self, forKey: key) {
            if !cached.isStale { return cached.value }
            Task { try? await refreshPlaylistItems(server: server, playlistKey: playlistKey, key: key) }
            return cached.value
        }

        return try await refreshPlaylistItems(server: server, playlistKey: playlistKey, key: key)
    }

    @discardableResult
    private func refreshPlaylistItems(server: PlexServer, playlistKey: String, key: String) async throws -> [PlexMetadata] {
        let items = try await getPlaylistItems(server: server, playlistKey: playlistKey)
        await LibraryCache.shared.set(items, forKey: key)
        return items
    }

    // MARK: - Cached Search

    func cachedSearch(server: PlexServer, query: String, sectionId: String? = nil, limit: Int = 20) async throws -> [Hub] {
        let key = CacheKey.search(query: query, sectionId: sectionId)

        // Search cache is short-lived — just return from cache if very fresh
        if let cached = await LibraryCache.shared.get([Hub].self, forKey: key) {
            if !cached.isStale { return cached.value }
        }

        let hubs = try await search(server: server, query: query, sectionId: sectionId, limit: limit)
        await LibraryCache.shared.set(hubs, forKey: key)
        return hubs
    }

    // MARK: - Private Helper

    private func cachedLibraryContents(server: PlexServer, sectionId: String, type: Int, key: String) async throws -> [PlexMetadata] {
        if let cached = await LibraryCache.shared.get([PlexMetadata].self, forKey: key) {
            if !cached.isStale { return cached.value }
            Task { try? await refreshLibraryContents(server: server, sectionId: sectionId, type: type, key: key) }
            return cached.value
        }

        return try await refreshLibraryContents(server: server, sectionId: sectionId, type: type, key: key)
    }

    @discardableResult
    private func refreshLibraryContents(server: PlexServer, sectionId: String, type: Int, key: String) async throws -> [PlexMetadata] {
        let items = try await getLibraryContents(server: server, sectionId: sectionId, type: type)
        await LibraryCache.shared.set(items, forKey: key)
        return items
    }
}
