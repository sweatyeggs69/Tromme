import CarPlay
import UIKit

// CarPlay Playlists templates.
@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Playlists

    func makePlaylistsList() -> CPListTemplate {
        let template = CPListTemplate(title: "Playlists", sections: [])
        loadPlaylists(into: template)
        return template
    }

    func loadPlaylists(into template: CPListTemplate) {
        guard let server else { return }
        let generation = contentGeneration
        Task {
            let playlists: [PlexPlaylist]
            do {
                playlists = try await client.cachedPlaylists(server: server)
            } catch {
                guard generation == contentGeneration else { return }
                let retry = makeRetryItem(into: template) { [weak self = self] in
                    self?.loadPlaylists(into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            guard generation == contentGeneration else { return }
            let musicPlaylists = playlists.filter { $0.isMusicPlaylist }
            let items = musicPlaylists.prefix(CPListTemplate.maximumItemCount).map { playlist -> CPListItem in
                let songCount = playlist.leafCount.map { "\($0) songs" }
                let item = CPListItem(text: playlist.title, detailText: songCount)
                item.accessoryType = .disclosureIndicator
                loadArtwork(path: playlist.thumb ?? playlist.composite, into: item, server: server, client: client)
                let key = playlist.key ?? playlist.ratingKey
                let title = playlist.title
                item.handler = { [weak self = self] _, completion in
                    self?.showPlaylistTracks(playlistKey: key, playlistTitle: title)
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
    }

    func showPlaylistTracks(playlistKey: String, playlistTitle: String) {
        guard let server else { return }
        let template = CPListTemplate(title: playlistTitle, sections: [])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        loadPlaylistTracks(playlistKey: playlistKey, server: server, client: client, into: template)
    }

    func loadPlaylistTracks(playlistKey: String, server: PlexServer, client: PlexAPIClient, into template: CPListTemplate) {
        Task {
            let tracks: [PlexMetadata]
            do {
                tracks = try await client.cachedPlaylistItems(server: server, playlistKey: playlistKey)
            } catch {
                let retry = makeRetryItem(into: template) { [weak self = self] in
                    self?.loadPlaylistTracks(playlistKey: playlistKey, server: server, client: client, into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            guard !tracks.isEmpty else { return }

            let shuffleItem = CPListItem(text: "Shuffle", detailText: "\(tracks.count) songs", image: UIImage(systemName: "shuffle"))
            shuffleItem.handler = { [weak self = self] _, completion in
                guard let self else { completion(); return }
                if !self.player.isShuffled { self.player.toggleShuffle() }
                self.player.play(tracks: tracks, startingAt: 0)
                self.pushNowPlaying()
                completion()
            }

            let trackItems: [CPListTemplateItem] = tracks.prefix(CPListTemplate.maximumItemCount - 1).enumerated().map { index, track -> CPListItem in
                let item = CPListItem(text: track.title, detailText: track.artistDisplayName)
                loadArtwork(path: track.thumb ?? track.parentThumb, into: item, server: server, client: client)
                item.handler = { [weak self = self] _, completion in
                    self?.player.play(tracks: tracks, startingAt: index)
                    self?.pushNowPlaying()
                    completion()
                }
                return item
            }

            var allItems: [CPListTemplateItem] = [shuffleItem]
            allItems.append(contentsOf: trackItems)
            template.updateSections([CPListSection(items: allItems)])
        }
    }
}
