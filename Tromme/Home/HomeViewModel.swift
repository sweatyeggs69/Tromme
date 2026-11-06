import SwiftUI
import Observation

@Observable @MainActor
final class HomeViewModel {
    let isPreviewMode: Bool

    private(set) var favoriteTracks: [PlexMetadata]
    private(set) var recentTracks: [PlexMetadata]
    private(set) var playlists: [PlexPlaylist]
    private(set) var recentAlbums: [PlexMetadata]
    private(set) var featuredAlbums: [PlexMetadata]
    private(set) var hubs: [Hub] = []
    private(set) var isLoadingFavorites: Bool
    private(set) var isLoadingPlaylists: Bool

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
        isLoadingFavorites = !isPreviewMode
        isLoadingPlaylists = !isPreviewMode
    }

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
            Task { await LibrarySyncService.shared.refreshIfNeeded(client: client, server: server, sectionId: sectionId, force: true) }
            await client.refreshDynamicContent(server: server, sectionId: sectionId)
        }
        await load(context)
        await loadHubs(context)
    }

    private static var didRefreshSinceLaunch = false

    func refreshOnColdLaunch(_ context: Context) async {
        guard !isPreviewMode, !Self.didRefreshSinceLaunch,
              context.server != nil, context.sectionId != nil else { return }
        Self.didRefreshSinceLaunch = true
        await refresh(context)
    }

    func loadHubs(_ context: Context) async {
        guard !isPreviewMode,
              let server = context.server,
              let sectionId = context.sectionId else { return }
        let scope = "\(server.uri)|\(sectionId)"
        if hubs.isEmpty {
            hubs = HomeHubCache.load(scope: scope).filter(HomeHubConfig.isSupported)
        }
        guard let fetched = try? await context.client.getSectionHubs(server: server, sectionId: sectionId),
              !Task.isCancelled else { return }
        let previous = Dictionary(hubs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = fetched.filter(HomeHubConfig.isSupported).map { hub in
            guard hub.metadata?.isEmpty ?? true, let kept = previous[hub.id], !(kept.metadata?.isEmpty ?? true) else { return hub }
            return kept
        }
        HomeHubCache.save(merged, scope: scope)
        hubs = merged
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
        guard let fresh = try? await context.client.cachedRecentlyPlayed(server: server, sectionId: sectionId) else { return }
        withAnimation(.easeIn(duration: 0.25)) {
            recentTracks = Array(fresh.prefix(10))
        }
    }

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

    private func loadHomeContent(_ context: Context) async {
        if favoriteTracks.isEmpty { isLoadingFavorites = true }
        if playlists.isEmpty { isLoadingPlaylists = true }

        guard let server = context.server,
              let sectionId = context.sectionId else { return }
        let client = context.client

        enum HomeLoadResult: Sendable {
            case favorites([PlexMetadata]?)
            case recentlyPlayed([PlexMetadata]?)
            case playlists([PlexPlaylist]?)
            case recentlyAdded([PlexMetadata]?)
        }

        await withTaskGroup(of: HomeLoadResult.self) { group in
            group.addTask {
                .favorites(await Self.fetchWithRetryOnFailure {
                    try await client.cachedFavoriteTracks(server: server, sectionId: sectionId)
                })
            }
            group.addTask {
                .recentlyPlayed(await Self.fetchWithRetryOnFailure {
                    try await client.cachedRecentlyPlayed(server: server, sectionId: sectionId)
                })
            }
            group.addTask {
                .playlists(await Self.fetchWithRetryOnFailure {
                    try await client.cachedPlaylists(server: server)
                })
            }
            group.addTask {
                .recentlyAdded(await Self.fetchWithRetryOnFailure {
                    try await client.cachedRecentlyAdded(server: server, sectionId: sectionId)
                })
            }

            for await result in group {
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.25)) {
                    switch result {
                    case .favorites(let value):
                        if let value { applyFavorites(plexFavorites: value) }
                        isLoadingFavorites = false
                    case .recentlyPlayed(let value):
                        if let value { recentTracks = Array(value.prefix(10)) }
                    case .playlists(let value):
                        if let value { playlists = Array(value.filter(\.isMusicPlaylist).prefix(10)) }
                        isLoadingPlaylists = false
                    case .recentlyAdded(let value):
                        if let value { recentAlbums = Array(value.prefix(10)) }
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }
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
        guard !NetworkStatus.shared.isExpensive,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let trackPixelSize = ArtworkView.recommendedTranscodeSize(
            pointSize: AppStyle.TrackGrid.artworkSize,
            displayScale: displayScale
        )
        let cardPixelSize = ArtworkView.recommendedTranscodeSize(
            pointSize: AppStyle.Artwork.card,
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
