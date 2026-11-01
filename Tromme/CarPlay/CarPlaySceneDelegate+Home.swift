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

        homeSections = [nil, nil, nil, nil]
        var completedCount = 0

        func rebuildSections() {
            completedCount += 1
            guard completedCount == 4 else { return }
            guard generation == self.contentGeneration else { return }
            var sections = self.homeSections.compactMap { $0 }
            if sections.isEmpty {
                let retry = makeRetryItem(into: template) { [weak self] in
                    self?.loadHomeContent(into: template)
                }
                sections.append(CPListSection(items: [retry]))
            }
            template.updateSections(sections)
        }

        Task {
            self.homeSections[0] = await loadFavoritesSection(server: server, sectionId: sectionId)
            rebuildSections()
        }

        Task {
            if let recentlyAdded = try? await client.cachedRecentlyAdded(server: server, sectionId: sectionId, limit: 10),
               !recentlyAdded.isEmpty {
                let limited = Array(recentlyAdded.prefix(10))
                let imageRow = await makeImageRow(
                    title: "Recently Added",
                    items: limited,
                    server: server,
                    client: client,
                    onImageSelect: { [weak self = self] index in
                        let album = limited[index]
                        self?.showAlbumTracks(albumRatingKey: album.ratingKey, albumTitle: album.title, artistName: album.parentTitle, albumThumb: album.thumb)
                    },
                    onRowSelect: { [weak self = self] in
                        self?.showRecentlyAddedList(limited)
                    }
                )
                self.homeSections[1] = CPListSection(items: [imageRow])
            }
            rebuildSections()
        }

        Task {
            self.homeSections[2] = await loadPlaylistsSection(server: server)
            rebuildSections()
        }

        Task {
            self.homeSections[3] = await loadRecentlyPlayedSection(server: server, sectionId: sectionId)
            rebuildSections()
        }
    }

    func loadPlaylistsSection(server: PlexServer) async -> CPListSection? {
        guard let playlists = try? await client.cachedPlaylists(server: server) else { return nil }
        let music = playlists.filter { $0.isMusicPlaylist }
        guard !music.isEmpty else { return nil }
        let limited = Array(music.prefix(CPMaximumNumberOfGridImages))
        let row = await makeImageRow(
            title: "Playlists",
            thumbPaths: limited.map { $0.thumb ?? $0.composite },
            elementTitles: limited.map { $0.title },
            elementSubtitles: limited.map { _ in nil },
            server: server,
            client: client,
            onImageSelect: { [weak self] index in
                let playlist = limited[index]
                self?.showPlaylistTracks(playlistKey: playlist.key ?? playlist.ratingKey, playlistTitle: playlist.title)
            },
            onRowSelect: { [weak self] in
                guard let self else { return }
                self.interfaceController?.pushTemplate(self.makePlaylistsList(), animated: true, completion: nil)
            }
        )
        return CPListSection(items: [row])
    }

    func loadFavoritesSection(server: PlexServer, sectionId: String) async -> CPListSection? {
        guard let favorites = try? await client.cachedFavoriteTracks(server: server, sectionId: sectionId),
              !favorites.isEmpty else { return nil }
        let sorted = favorites.sorted { ($0.userRating ?? 0) > ($1.userRating ?? 0) }
        let preview = Array(sorted.prefix(4))
        let full = Array(sorted.prefix(10))
        let row = await makeCondensedImageRow(
            title: "Favorites",
            items: preview,
            server: server,
            client: client,
            elementTitle: { $0.title },
            elementSubtitle: { $0.artistDisplayName },
            onElementSelect: { [weak self = self] index in
                self?.player.play(tracks: preview, startingAt: index)
                self?.pushNowPlaying()
            },
            onHeaderSelect: { [weak self = self] in
                self?.showTrackList(title: "Favorites", tracks: full)
            }
        )
        return CPListSection(items: [row])
    }

    func startObservingFavorites() {
        favoritesObservationTask?.cancel()
        favoritesObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .favoritesDidChange) {
                guard !Task.isCancelled, let self else { return }
                guard let homeTemplate = self.homeTemplate,
                      let server = self.server, let sectionId = self.sectionId else { continue }
                self.homeSections[0] = await self.loadFavoritesSection(server: server, sectionId: sectionId)
                let sections = self.homeSections.compactMap { $0 }
                guard !sections.isEmpty else { continue }
                homeTemplate.updateSections(sections)
            }
        }
    }

    func loadRecentlyPlayedSection(server: PlexServer, sectionId: String) async -> CPListSection? {
        guard let recentlyPlayed = try? await client.cachedRecentlyPlayed(server: server, sectionId: sectionId, limit: 10),
              !recentlyPlayed.isEmpty else { return nil }
        let preview = Array(recentlyPlayed.prefix(4))
        let full = Array(recentlyPlayed.prefix(10))
        let row = await makeCondensedImageRow(
            title: "Recently Played",
            items: preview,
            server: server,
            client: client,
            elementTitle: { $0.title },
            elementSubtitle: { $0.artistDisplayName },
            onElementSelect: { [weak self = self] index in
                self?.player.play(tracks: preview, startingAt: index)
                self?.pushNowPlaying()
            },
            onHeaderSelect: { [weak self = self] in
                self?.showTrackList(title: "Recently Played", tracks: full, showActions: false)
            }
        )
        return CPListSection(items: [row])
    }

    func startObservingRecentlyPlayed() {
        recentlyPlayedObservationTask?.cancel()
        recentlyPlayedObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .recentlyPlayedDidChange) {
                guard !Task.isCancelled, let self else { return }
                guard let homeTemplate = self.homeTemplate,
                      let server = self.server, let sectionId = self.sectionId else { continue }
                self.homeSections[3] = await self.loadRecentlyPlayedSection(server: server, sectionId: sectionId)
                let sections = self.homeSections.compactMap { $0 }
                guard !sections.isEmpty else { continue }
                homeTemplate.updateSections(sections)
            }
        }
    }
}
