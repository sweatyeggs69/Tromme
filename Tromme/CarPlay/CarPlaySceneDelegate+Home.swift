import CarPlay
import UIKit

@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Home

    func makeHomeList() -> CPListTemplate {
        let template = CPListTemplate(title: "Home", sections: [])
        loadHomeContent(into: template)
        return template
    }

    func loadHomeContent(into template: CPListTemplate) {
        guard let server, let sectionId else { return }
        let generation = contentGeneration
        let scope = "\(server.uri)|\(sectionId)"

        homeRowSections = [:]
        homeHubs = HomeHubCache.load(scope: scope).filter(HomeHubConfig.isSupported)
        homeSettingsSignature = currentHomeSettingsSignature()
        var pending = 3

        func finish() {
            pending -= 1
            guard pending == 0, generation == self.contentGeneration else { return }
            if self.homeRowSections.isEmpty {
                let retry = makeRetryItem(into: template) { [weak self] in
                    self?.loadHomeContent(into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
            }
        }

        Task {
            await self.rebuildFavoritesRow(server: server, sectionId: sectionId)
            guard generation == self.contentGeneration else { return }
            self.applyHomeSections()
            finish()
        }

        Task {
            self.homeRecentTracks = (try? await client.cachedRecentlyPlayed(server: server, sectionId: sectionId)) ?? []
            guard generation == self.contentGeneration else { return }
            await self.rebuildHubRows(server: server)
            guard generation == self.contentGeneration else { return }
            self.applyHomeSections()
            finish()
        }

        Task {
            if let fetched = try? await client.getSectionHubs(server: server, sectionId: sectionId) {
                guard generation == self.contentGeneration else { return }
                let previous = Dictionary(self.homeHubs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let merged = fetched.filter(HomeHubConfig.isSupported).map { hub in
                    guard hub.metadata?.isEmpty ?? true, let kept = previous[hub.id], !(kept.metadata?.isEmpty ?? true) else { return hub }
                    return kept
                }
                HomeHubCache.save(merged, scope: scope)
                self.homeHubs = merged
                await self.rebuildHubRows(server: server)
                guard generation == self.contentGeneration else { return }
                self.applyHomeSections()
            }
            finish()
        }
    }

    // MARK: - Ordering

    func orderedHomeItems() -> [Hub] {
        let defaults = UserDefaults.standard
        let hidden = defaults.string(forKey: HomeHubConfig.hiddenSectionsKey) ?? ""
        let order = HomeHubConfig.ids(defaults.string(forKey: HomeHubConfig.orderKey) ?? "")
        let shown = ([HomeHubConfig.favorites] + homeHubs).filter {
            HomeHubConfig.isEnabled($0, hiddenRaw: hidden)
        }
        return HomeHubConfig.ordered(shown, by: order)
    }

    func applyHomeSections() {
        guard let homeTemplate else { return }
        homeTemplate.updateSections(orderedHomeItems().compactMap { homeRowSections[$0.id] })
    }

    func currentHomeSettingsSignature() -> String {
        let defaults = UserDefaults.standard
        return [HomeHubConfig.orderKey, HomeHubConfig.hiddenSectionsKey, HomeHubConfig.recentlyPlayedLevelKey]
            .map { defaults.string(forKey: $0) ?? "" }
            .joined(separator: "|")
    }

    func startObservingHomeSettings() {
        homeSettingsObservationTask?.cancel()
        homeSettingsObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                guard !Task.isCancelled, let self else { return }
                let signature = self.currentHomeSettingsSignature()
                guard signature != self.homeSettingsSignature else { continue }
                self.homeSettingsSignature = signature
                if let server = self.server {
                    await self.rebuildHubRows(server: server)
                }
                self.applyHomeSections()
            }
        }
    }

    // MARK: - Favorites

    func rebuildFavoritesRow(server: PlexServer, sectionId: String) async {
        let id = HomeHubConfig.favorites.id
        guard let favorites = try? await client.cachedFavoriteTracks(server: server, sectionId: sectionId),
              !favorites.isEmpty else {
            homeRowSections[id] = nil
            return
        }
        let sorted = favorites.sorted { ($0.userRating ?? 0) > ($1.userRating ?? 0) }
        let row = await makeTrackHubRow(title: "Favorites", tracks: Array(sorted.prefix(10)), server: server, showActions: true)
        homeRowSections[id] = CPListSection(items: [row])
    }

    func startObservingFavorites() {
        favoritesObservationTask?.cancel()
        favoritesObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .favoritesDidChange) {
                guard !Task.isCancelled, let self else { return }
                guard self.homeTemplate != nil,
                      let server = self.server, let sectionId = self.sectionId else { continue }
                await self.rebuildFavoritesRow(server: server, sectionId: sectionId)
                self.applyHomeSections()
            }
        }
    }

    // MARK: - Recently Played

    func startObservingRecentlyPlayed() {
        recentlyPlayedObservationTask?.cancel()
        recentlyPlayedObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .recentlyPlayedDidChange) {
                guard !Task.isCancelled, let self else { return }
                guard self.homeTemplate != nil,
                      let server = self.server, let sectionId = self.sectionId,
                      let fresh = try? await self.client.cachedRecentlyPlayed(server: server, sectionId: sectionId) else { continue }
                self.homeRecentTracks = fresh
                for hub in self.homeHubs where HomeHubConfig.isRecentlyPlayed(hub) {
                    await self.rebuildHubRow(hub, server: server)
                }
                self.applyHomeSections()
            }
        }
    }

    // MARK: - Plex Hubs

    func rebuildHubRows(server: PlexServer) async {
        homeHubsRevision += 1
        let revision = homeHubsRevision
        let hubs = homeHubs
        var built: [String: CPListSection] = [:]
        for hub in hubs {
            built[hub.id] = await makeHubSection(hub, server: server)
            guard revision == homeHubsRevision else { return }
        }
        let favoritesId = HomeHubConfig.favorites.id
        homeRowSections = built.merging(homeRowSections.filter { $0.key == favoritesId }) { current, _ in current }
    }

    func rebuildHubRow(_ hub: Hub, server: PlexServer) async {
        let revision = homeHubsRevision
        let section = await makeHubSection(hub, server: server)
        guard revision == homeHubsRevision else { return }
        homeRowSections[hub.id] = section
    }

    func makeHubSection(_ hub: Hub, server: PlexServer) async -> CPListSection? {
        let level = UserDefaults.standard.string(forKey: HomeHubConfig.recentlyPlayedLevelKey) ?? "songs"
        let shown = HomeHubConfig.isRecentlyPlayed(hub)
            ? HomeHubConfig.recentlyPlayedHub(hub, level: level, recentTracks: homeRecentTracks)
            : hub
        let items = shown.metadata ?? []
        guard !items.isEmpty else { return nil }
        let title = shown.title ?? ""
        let row: CPListImageRowItem
        switch HomeHubConfig.rowType(of: shown) {
        case "track":
            row = await makeTrackHubRow(title: title, tracks: items, server: server, showActions: !HomeHubConfig.isRecentlyPlayed(hub))
        case "artist":
            let limited = Array(items.prefix(CPMaximumNumberOfGridImages))
            row = await makeImageRow(
                title: title,
                items: limited,
                server: server,
                client: client,
                elementTitle: { $0.title },
                onImageSelect: { [weak self] index in
                    self?.showArtistAlbums(artist: limited[index])
                },
                onRowSelect: { [weak self] in
                    self?.showArtistList(title: title, artists: items)
                }
            )
        default:
            let limited = Array(items.prefix(CPMaximumNumberOfGridImages))
            row = await makeImageRow(
                title: title,
                items: limited,
                server: server,
                client: client,
                onImageSelect: { [weak self] index in
                    let album = limited[index]
                    self?.showAlbumTracks(albumRatingKey: album.ratingKey, albumTitle: album.title, artistName: album.parentTitle, albumThumb: album.thumb, releaseYear: album.releaseYear)
                },
                onRowSelect: { [weak self] in
                    self?.showAlbumList(title: title, albums: items)
                }
            )
        }
        return CPListSection(items: [row])
    }

    func makeTrackHubRow(title: String, tracks: [PlexMetadata], server: PlexServer, showActions: Bool) async -> CPListImageRowItem {
        let preview = Array(tracks.prefix(4))
        return await makeCondensedImageRow(
            title: title,
            items: preview,
            server: server,
            client: client,
            elementTitle: { $0.title },
            elementSubtitle: { $0.artistDisplayName },
            onElementSelect: { [weak self] index in
                self?.player.play(tracks: preview, startingAt: index)
                self?.pushNowPlaying()
            },
            onHeaderSelect: { [weak self] in
                self?.showTrackList(title: title, tracks: tracks, showActions: showActions)
            }
        )
    }
}
