import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    private var server: PlexServer? { AppContext.shared.serverConnection?.currentServer }
    private var sectionId: String? { AppContext.shared.serverConnection?.currentLibrarySectionId }
    private var client: PlexAPIClient? { AppContext.shared.plexClient }
    private var player: AudioPlayerService? { AppContext.shared.audioPlayer }

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        configureNowPlaying()
        updateRootTemplate()
    }

    private func updateRootTemplate() {
        guard let interfaceController else { return }
        if server != nil, sectionId != nil {
            interfaceController.setRootTemplate(makeRootTabBar(), animated: true, completion: nil)
        } else {
            interfaceController.setRootTemplate(makeSignInTemplate(), animated: true, completion: nil)
        }
    }

    private func makeSignInTemplate() -> CPListTemplate {
        let item = CPListItem(text: "Sign In to Plex to Start Listening", detailText: "Open Tromme on your iPhone to sign in")
        item.isEnabled = false
        let section = CPListSection(items: [item])
        let template = CPListTemplate(title: "Tromme", sections: [section])
        return template
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CPNowPlayingTemplate.shared.remove(self)
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
        }
    }

    // MARK: - Root Tab Bar

    private func makeRootTabBar() -> CPTabBarTemplate {
        let artistsTemplate = makeArtistsTab()
        let albumsTemplate = makeAlbumsTab()
        let playlistsTemplate = makePlaylistsTab()

        let tabBar = CPTabBarTemplate(templates: [artistsTemplate, albumsTemplate, playlistsTemplate])
        return tabBar
    }

    // MARK: - Artists Tab

    private func makeArtistsTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Artists", sections: [])
        template.tabImage = UIImage(systemName: "music.mic")
        template.tabTitle = "Artists"
        loadArtists(into: template)
        return template
    }

    private func loadArtists(into template: CPListTemplate) {
        guard let server, let sectionId, let client else { return }
        Task {
            let artists = (try? await client.cachedArtists(server: server, sectionId: sectionId)) ?? []
            let items = artists.prefix(CPListTemplate.maximumItemCount).map { artist -> CPListItem in
                let item = CPListItem(text: artist.title, detailText: nil)
                item.accessoryType = .disclosureIndicator
                loadArtwork(path: artist.thumb, into: item, server: server, client: client)
                let ratingKey = artist.ratingKey
                item.handler = { [weak self] _, completion in
                    self?.showArtistAlbums(artistRatingKey: ratingKey, artistName: artist.title)
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
    }

    private func showArtistAlbums(artistRatingKey: String, artistName: String) {
        guard let server, let client else { return }
        let template = CPListTemplate(title: artistName, sections: [])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            let albums = (try? await client.cachedChildren(server: server, ratingKey: artistRatingKey)) ?? []
            let items = albums.filter { $0.type == "album" }.prefix(CPListTemplate.maximumItemCount).map { album -> CPListItem in
                let item = CPListItem(text: album.title, detailText: album.releaseYear)
                item.accessoryType = .disclosureIndicator
                loadArtwork(path: album.thumb, into: item, server: server, client: client)
                let ratingKey = album.ratingKey
                let albumTitle = album.title
                item.handler = { [weak self] _, completion in
                    self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle)
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
    }

    // MARK: - Albums Tab

    private func makeAlbumsTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Albums", sections: [])
        template.tabImage = UIImage(systemName: "square.stack")
        template.tabTitle = "Albums"
        loadAlbums(into: template)
        return template
    }

    private func loadAlbums(into template: CPListTemplate) {
        guard let server, let sectionId, let client else { return }
        Task {
            let albums = (try? await client.cachedAlbums(server: server, sectionId: sectionId)) ?? []
            let items = albums.prefix(CPListTemplate.maximumItemCount).map { album -> CPListItem in
                let artist = album.parentTitle ?? ""
                let item = CPListItem(text: album.title, detailText: artist)
                item.accessoryType = .disclosureIndicator
                loadArtwork(path: album.thumb, into: item, server: server, client: client)
                let ratingKey = album.ratingKey
                let albumTitle = album.title
                item.handler = { [weak self] _, completion in
                    self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle)
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
    }

    // MARK: - Album Tracks

    private func showAlbumTracks(albumRatingKey: String, albumTitle: String) {
        guard let server, let client else { return }
        let template = CPListTemplate(title: albumTitle, sections: [])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            let tracks = (try? await client.cachedChildren(server: server, ratingKey: albumRatingKey)) ?? []
            let playableTracks = tracks.filter { $0.type == "track" }
            let items = playableTracks.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, track -> CPListItem in
                let trackNumber = track.index.map { "\($0). " } ?? ""
                let item = CPListItem(text: "\(trackNumber)\(track.title)", detailText: track.durationFormatted)
                item.isExplicitContent = false
                let capturedTracks = Array(playableTracks)
                let capturedIndex = index
                item.handler = { [weak self] _, completion in
                    self?.player?.play(tracks: capturedTracks, startingAt: capturedIndex)
                    self?.pushNowPlaying()
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
    }

    // MARK: - Playlists Tab

    private func makePlaylistsTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Playlists", sections: [])
        template.tabImage = UIImage(systemName: "list.bullet")
        template.tabTitle = "Playlists"
        loadPlaylists(into: template)
        return template
    }

    private func loadPlaylists(into template: CPListTemplate) {
        guard let server, let client else { return }
        Task {
            let playlists = (try? await client.cachedPlaylists(server: server)) ?? []
            let musicPlaylists = playlists.filter(\.isMusicPlaylist)
            let items = musicPlaylists.prefix(CPListTemplate.maximumItemCount).map { playlist -> CPListItem in
                let count = playlist.leafCount.map { "\($0) tracks" }
                let item = CPListItem(text: playlist.title, detailText: count)
                item.accessoryType = .disclosureIndicator
                loadArtwork(path: playlist.composite, into: item, server: server, client: client)
                let playlistKey = playlist.ratingKey
                let playlistTitle = playlist.title
                item.handler = { [weak self] _, completion in
                    self?.showPlaylistTracks(playlistKey: playlistKey, playlistTitle: playlistTitle)
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
    }

    private func showPlaylistTracks(playlistKey: String, playlistTitle: String) {
        guard let server, let client else { return }
        let template = CPListTemplate(title: playlistTitle, sections: [])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            let tracks = (try? await client.cachedPlaylistItems(server: server, playlistKey: playlistKey)) ?? []
            let items = tracks.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, track -> CPListItem in
                let item = CPListItem(text: track.title, detailText: track.artistName)
                let capturedTracks = Array(tracks)
                let capturedIndex = index
                item.handler = { [weak self] _, completion in
                    self?.player?.play(tracks: capturedTracks, startingAt: capturedIndex)
                    self?.pushNowPlaying()
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
    }

    // MARK: - Now Playing

    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.isAlbumArtistButtonEnabled = true

        let shuffleButton = CPNowPlayingShuffleButton { [weak self] _ in
            self?.player?.toggleShuffle()
        }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            self?.player?.cycleRepeatMode()
        }
        nowPlaying.updateNowPlayingButtons([shuffleButton, repeatButton])
    }

    private func pushNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        // Avoid pushing if already visible
        if interfaceController?.topTemplate !== nowPlaying {
            interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: - Artwork Loading

    private func loadArtwork(path: String?, into item: CPListItem, server: PlexServer, client: PlexAPIClient) {
        guard let url = client.artworkURL(server: server, path: path, width: 120, height: 120) else { return }
        Task {
            guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 120) else { return }
            item.setImage(image)
        }
    }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlaySceneDelegate: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let player, !player.upcomingTracks.isEmpty else { return }
        let tracks = player.upcomingTracks
        let items = tracks.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artistName)
            item.handler = { [weak self] _, completion in
                self?.player?.playFromQueue(at: index)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Up Next", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let player, let track = player.currentTrack,
              let albumRatingKey = track.parentRatingKey else { return }
        showAlbumTracks(albumRatingKey: albumRatingKey, albumTitle: track.albumName)
    }
}
