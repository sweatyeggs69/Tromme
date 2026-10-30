import Foundation

extension PlexAPIClient {

    // MARK: - Library Sections

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
        var releases = try await cachedChildren(server: server, ratingKey: artist.ratingKey, sectionId: sectionId, kind: .artistAlbums)
        let releaseKeys = Set(releases.map(\.ratingKey))
        let artistTracks = try await cachedArtistTracks(server: server, sectionId: sectionId, artist: artist)
        let missingReleaseKeys = Set(artistTracks.compactMap(\.parentRatingKey)).subtracting(releaseKeys)

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

    private static let favoriteMinRating: Double = 4

    func cachedFavoriteTracks(server: PlexServer, sectionId: String) async throws -> [PlexMetadata] {
        let scope = scope(server, sectionId)
        if await LibraryStore.shared.isReady(kind: LibraryStore.Kind.track, scope: scope) {
            return await LibraryStore.shared.favorites(scope: scope, minUserRating: Self.favoriteMinRating)
        }
        return try await getFavoriteTracks(server: server, sectionId: sectionId)
    }

    // MARK: - Similar Artists

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

    private func compilationCreditedTracks(server: PlexServer, sectionId: String, artistRatingKey: String, artistTitle: String) async throws -> [PlexMetadata] {
        let allTracks = try await cachedTracks(server: server, sectionId: sectionId)
        let artistTitleLower = artistTitle.lowercased()
        return allTracks.filter { track in
            guard track.grandparentRatingKey != artistRatingKey else { return false }
            guard let credit = track.originalTitle?.lowercased(), !credit.isEmpty else { return false }
            return credit.contains(artistTitleLower)
        }
    }

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

    enum ChildrenKind {
        case albumTracks
        case artistAlbums
    }

    private func fetchChildren(server: PlexServer, ratingKey: String, sectionId: String?, kind: ChildrenKind) async throws -> [PlexMetadata] {
        switch kind {
        case .albumTracks:
            return try await getAlbumTracks(server: server, ratingKey: ratingKey)
        case .artistAlbums:
            guard let sectionId else { return [] }
            return try await getArtistAlbums(server: server, sectionId: sectionId, artistRatingKey: ratingKey)
        }
    }

    func cachedChildren(
        server: PlexServer,
        ratingKey: String,
        updatedAt: Int? = nil,
        sectionId: String? = nil,
        kind: ChildrenKind = .albumTracks
    ) async throws -> [PlexMetadata] {
        let serverId = server.machineIdentifier
        let resolvedSection: String?
        if let sectionId {
            resolvedSection = sectionId
        } else {
            resolvedSection = await LibraryStore.shared.sectionId(ofRatingKey: ratingKey, serverId: serverId)
        }
        guard let resolvedSection else {
            return try await fetchChildren(server: server, ratingKey: ratingKey, sectionId: nil, kind: kind)
        }

        let scope = scope(server, resolvedSection)
        var items = await LibraryStore.shared.children(of: ratingKey, scope: scope)
        if items.isEmpty {
            try? await awaitLibrary(kind: LibraryStore.Kind.track, server: server, sectionId: resolvedSection)
            items = await LibraryStore.shared.children(of: ratingKey, scope: scope)
        }
        if items.isEmpty {
            return try await fetchChildren(server: server, ratingKey: ratingKey, sectionId: resolvedSection, kind: kind)
        }
        return items
    }

    // MARK: - Playlists

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

    func refreshPlaylists(server: PlexServer) async throws {
        try await LibrarySyncService.shared.refreshPlaylists(client: self, server: server)
    }

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
        Notification.Name.postLibraryContentDidChange()
    }

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
        Notification.Name.postLibraryContentDidChange()
    }

    // MARK: - Metadata (single item)

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

    func smartRefresh(server: PlexServer, sectionId: String, forceLibrarySync: Bool = false) async {
        async let dynamic: Void = refreshDynamicContent(server: server, sectionId: sectionId)
        await LibrarySyncService.shared.refreshIfNeeded(client: self, server: server, sectionId: sectionId, force: forceLibrarySync)
        await dynamic
    }

    func refreshDynamicContent(server: PlexServer, sectionId: String) async {
        async let playlists: Void = { try? await refreshPlaylists(server: server) }()
        await refreshUserState(server: server, sectionId: sectionId)
        await playlists
    }

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
        Notification.Name.postLibraryContentDidChange()
    }

    func refreshItem(server: PlexServer, ratingKey: String) async {
        guard let sectionId = await LibraryStore.shared.sectionId(ofRatingKey: ratingKey, serverId: server.machineIdentifier),
              let fresh = try? await getMetadata(server: server, ratingKey: ratingKey) else { return }
        await LibraryStore.shared.applyTrackUpdates([fresh], scope: scope(server, sectionId))
    }

    func fetchMetadata(server: PlexServer, ratingKeys: [String], batchSize: Int = 50) async -> [PlexMetadata] {
        var result: [PlexMetadata] = []
        for start in stride(from: 0, to: ratingKeys.count, by: batchSize) {
            let batch = Array(ratingKeys[start..<min(start + batchSize, ratingKeys.count)])
            if let items = try? await getMetadata(server: server, ratingKeys: batch) { result += items }
        }
        return result
    }

    // MARK: - Artwork Prefetching

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
