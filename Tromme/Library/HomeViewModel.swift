import SwiftUI
import Observation

/// Loading for `HomeView`; the view only renders this state.
@Observable @MainActor
final class HomeViewModel {
    let isPreviewMode: Bool

    private(set) var favoriteTracks: [PlexMetadata]
    private(set) var recentTracks: [PlexMetadata]
    private(set) var playlists: [PlexPlaylist]
    private(set) var recentAlbums: [PlexMetadata]
    private(set) var featuredAlbums: [PlexMetadata]
    private(set) var isLoading: Bool

    // Same keys the view used through @AppStorage, so existing picks carry over.
    private static let featuredAlbumRatingKeysKey = "featuredAlbumRatingKeys"
    private static let featuredAlbumLastRefreshedAtKey = "featuredAlbumLastRefreshedAt"

    init(
        previewRecentTracks: [PlexMetadata]? = nil,
        previewPlaylists: [PlexPlaylist]? = nil,
        previewRecentAlbums: [PlexMetadata]? = nil
    ) {
        favoriteTracks = Array((previewRecentTracks ?? []).prefix(10))
        recentTracks = previewRecentTracks ?? []
        playlists = previewPlaylists ?? []
        recentAlbums = previewRecentAlbums ?? []
        featuredAlbums = Array((previewRecentAlbums ?? []).shuffled().prefix(5))
        isPreviewMode = previewRecentTracks != nil || previewPlaylists != nil || previewRecentAlbums != nil
        isLoading = !isPreviewMode
    }

    /// Everything the loaders need from the environment.
    struct Context {
        let server: PlexServer?
        let sectionId: String?
        let client: PlexAPIClient
        let displayScale: CGFloat
    }

    func load(_ context: Context) async {
        guard !isPreviewMode else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadHomeContent(context) }
            group.addTask { await self.loadFeaturedAlbum(context, forced: false) }
        }
    }

    func refresh(_ context: Context) async {
        guard !isPreviewMode else { return }
        if let server = context.server, let sectionId = context.sectionId {
            let client = context.client
            // Full-library changes (new albums/tracks) sync in the background and arrive
            // via libraryContentDidChange; the quick part — play counts, ratings,
            // playlists — is awaited so the spinner covers it.
            // Forced: deletes/merges made in Plex don't always advance the section's updatedAt.
            Task { await LibrarySyncService.shared.refreshIfNeeded(client: client, server: server, sectionId: sectionId, force: true) }
            await client.refreshDynamicContent(server: server, sectionId: sectionId)
        }
        await load(context)
    }

    func libraryContentDidChange(_ context: Context) async {
        guard !isPreviewMode else { return }
        await loadHomeContent(context)
    }

    func favoritesDidChange(_ context: Context) async {
        guard !isPreviewMode,
              let server = context.server,
              let sectionId = context.sectionId else { return }
        if let favorites = try? await context.client.cachedFavoriteTracks(server: server, sectionId: sectionId) {
            applyFavorites(plexFavorites: favorites)
        }
    }

    func recentlyPlayedDidChange(_ context: Context) async {
        guard !isPreviewMode,
              let server = context.server,
              let sectionId = context.sectionId else { return }
        // The player already refreshed the played item in the store; just re-read it.
        guard let fresh = try? await context.client.cachedRecentlyPlayed(server: server, sectionId: sectionId) else { return }
        withAnimation(.easeIn(duration: 0.25)) {
            recentTracks = Array(fresh.prefix(10))
        }
    }

    /// The album's tracks for queue and playlist actions, or nil when there are none.
    func tracks(of album: PlexMetadata, _ context: Context) async -> [PlexMetadata]? {
        guard let server = context.server,
              let tracks = try? await context.client.cachedChildren(server: server, ratingKey: album.ratingKey, updatedAt: album.updatedAt),
              !tracks.isEmpty else { return nil }
        return tracks
    }

    private func loadFeaturedAlbum(_ context: Context, forced: Bool) async {
        guard let server = context.server,
              let sectionId = context.sectionId else { return }
        guard let albums = try? await context.client.cachedAlbums(server: server, sectionId: sectionId),
              !albums.isEmpty else { return }

        let defaults = UserDefaults.standard
        let storedKeys = defaults.string(forKey: Self.featuredAlbumRatingKeysKey) ?? ""
        let lastRefreshedAt = defaults.double(forKey: Self.featuredAlbumLastRefreshedAtKey)
        let oneHour: TimeInterval = 60 * 60
        let stale = (Date().timeIntervalSince1970 - lastRefreshedAt) >= oneHour

        if forced || stale || storedKeys.isEmpty {
            var pool = albums
            var picked: [PlexMetadata] = []
            for _ in 0..<min(5, pool.count) {
                guard let idx = pool.indices.randomElement() else { break }
                picked.append(pool.remove(at: idx))
            }
            featuredAlbums = picked
            defaults.set(picked.map(\.ratingKey).joined(separator: ","), forKey: Self.featuredAlbumRatingKeysKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.featuredAlbumLastRefreshedAtKey)
        } else {
            let keys = storedKeys.split(separator: ",").map(String.init)
            let matched = keys.compactMap { key in albums.first { $0.ratingKey == key } }
            if !matched.isEmpty {
                featuredAlbums = matched
            }
        }
    }

    /// Every row is a local query over the library store, so this is effectively instant.
    private func loadHomeContent(_ context: Context) async {
        let hadFavorites = !favoriteTracks.isEmpty
        let hadRecentTracks = !recentTracks.isEmpty
        let hadPlaylists = !playlists.isEmpty
        let hadRecentAlbums = !recentAlbums.isEmpty

        // Keep existing content visible during refresh; show loading spinners only
        // when there is no content yet.
        if !hadFavorites && !hadRecentTracks && !hadPlaylists && !hadRecentAlbums {
            isLoading = true
        }

        guard let server = context.server,
              let sectionId = context.sectionId else {
            favoriteTracks = []
            recentTracks = []
            playlists = []
            recentAlbums = []
            isLoading = false
            return
        }
        let client = context.client

        enum HomeLoadResult: Sendable {
            case favorites([PlexMetadata]?)
            case recentlyPlayed([PlexMetadata]?)
            case playlists([PlexPlaylist]?)
            case recentlyAdded([PlexMetadata]?)
        }

        let loadResults: [HomeLoadResult] = await withTaskGroup(of: HomeLoadResult.self, returning: [HomeLoadResult].self) { group in
            group.addTask {
                let value = await Self.fetchWithRetryOnFailure {
                    try await client.cachedFavoriteTracks(server: server, sectionId: sectionId)
                }
                return .favorites(value)
            }
            group.addTask {
                let value = await Self.fetchWithRetryOnFailure {
                    try await client.cachedRecentlyPlayed(server: server, sectionId: sectionId)
                }
                return .recentlyPlayed(value)
            }
            group.addTask {
                let value = await Self.fetchWithRetryOnFailure {
                    try await client.cachedPlaylists(server: server)
                }
                return .playlists(value)
            }
            group.addTask {
                let value = await Self.fetchWithRetryOnFailure {
                    try await client.cachedRecentlyAdded(server: server, sectionId: sectionId)
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
            } else if favoriteTracks.isEmpty {
                favoriteTracks = []
            }

            if let recentlyPlayedResult {
                recentTracks = Array(recentlyPlayedResult.prefix(10))
            } else if recentTracks.isEmpty {
                recentTracks = []
            }

            if let playlistsResult {
                playlists = Array(playlistsResult.filter(\.isMusicPlaylist).prefix(10))
            } else if playlists.isEmpty {
                playlists = []
            }

            if let recentlyAddedResult {
                recentAlbums = Array(recentlyAddedResult.prefix(10))
            } else if recentAlbums.isEmpty {
                recentAlbums = []
            }

            isLoading = false
        }

        let snapshotFavorites = favoriteTracks
        let snapshotRecentTracks = recentTracks
        let snapshotPlaylists = playlists
        let snapshotRecentAlbums = recentAlbums
        Task(priority: .utility) {
            await Self.prefetchHomeArtwork(
                server: server,
                client: client,
                displayScale: context.displayScale,
                favorites: snapshotFavorites,
                recentTracks: snapshotRecentTracks,
                playlists: snapshotPlaylists,
                recentAlbums: snapshotRecentAlbums
            )
        }
    }

    private nonisolated static func fetchWithRetryOnFailure<T: Sendable>(
        _ operation: @Sendable () async throws -> T
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

    private static func prefetchHomeArtwork(
        server: PlexServer,
        client: PlexAPIClient,
        displayScale: CGFloat,
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
