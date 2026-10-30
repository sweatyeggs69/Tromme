import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    var server: PlexServer? { AppContext.shared.serverConnection.currentServer }
    var sectionId: String? { AppContext.shared.serverConnection.currentLibrarySectionId }
    var client: PlexAPIClient { AppContext.shared.plexClient }
    var player: AudioPlayerService { AppContext.shared.audioPlayer }

    var shuffleNPButton: CPNowPlayingImageButton?
    var repeatNPButtons: [AudioPlayerService.RepeatMode: CPNowPlayingImageButton] = [:]
    var lastPublishedShuffleState: Bool?
    var lastPublishedRepeatMode: AudioPlayerService.RepeatMode?
    var magicMixButton: CPNowPlayingImageButton?
    var favoriteButton: CPNowPlayingImageButton?
    var currentTrackFavorited = false
    /// Last favorited state actually pushed to `favoriteButton.isSelected`. Several
    /// listeners (pushNowPlaying, the player-state observation loop) react to
    /// the same track-change event; without this guard they redundantly set the
    /// property with an unchanged value, and each set flashes the whole button
    /// row (shuffle included) as CarPlay redraws it.
    var lastPublishedFavoriteState: Bool?
    var lastPublishedMagicMixState: Bool?
    var observationTask: Task<Void, Never>?
    var connectionObservationTask: Task<Void, Never>?
    var recentlyPlayedObservationTask: Task<Void, Never>?
    var favoritesObservationTask: Task<Void, Never>?
    var homeSections: [CPListSection?] = [nil, nil, nil]
    var lastRootSignature: String?
    var lastServerURI: String?
    var homeTemplate: CPListTemplate?
    var artistsTemplate: CPListTemplate?
    var albumsTemplate: CPListTemplate?
    var playlistsTemplate: CPListTemplate?
    var contentGeneration = 0

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        lastRootSignature = nil
        lastServerURI = nil
        configureNowPlaying()
        updateRootTemplate()
        startObservingConnection()
        startObservingPlayer()
        startObservingFavorites()
        startObservingRecentlyPlayed()
        Task { await AppContext.shared.serverConnection.reprobe() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        observationTask?.cancel()
        observationTask = nil
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
        recentlyPlayedObservationTask?.cancel()
        recentlyPlayedObservationTask = nil
        favoritesObservationTask?.cancel()
        favoritesObservationTask = nil
        CPNowPlayingTemplate.shared.remove(self)
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
        }
        lastRootSignature = nil
        lastServerURI = nil
        homeTemplate = nil
        artistsTemplate = nil
        albumsTemplate = nil
        playlistsTemplate = nil
    }

    func updateRootTemplate() {
        guard let interfaceController else { return }
        let signature = rootSignature()
        let uri = server?.uri
        if signature == lastRootSignature {
            if uri != lastServerURI {
                lastServerURI = uri
                reloadTabContent()
            }
            return
        }
        lastRootSignature = signature
        lastServerURI = uri

        if server != nil, sectionId != nil {
            contentGeneration += 1
            let homeList = makeHomeList()
            homeList.tabTitle = "Home"
            homeList.tabImage = UIImage(systemName: "house.fill")

            let artistsList = makeArtistsList()
            artistsList.tabTitle = "Artists"
            artistsList.tabImage = UIImage(systemName: "music.mic")

            let albumsList = makeAlbumsList()
            albumsList.tabTitle = "Albums"
            albumsList.tabImage = UIImage(systemName: "square.stack")

            let playlistsList = makePlaylistsList()
            playlistsList.tabTitle = "Playlists"
            playlistsList.tabImage = UIImage(systemName: "music.note.list")

            homeTemplate = homeList
            artistsTemplate = artistsList
            albumsTemplate = albumsList
            playlistsTemplate = playlistsList

            let tabBar = CPTabBarTemplate(templates: [homeList, artistsList, albumsList, playlistsList])
            interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
        } else {
            homeTemplate = nil
            artistsTemplate = nil
            albumsTemplate = nil
            playlistsTemplate = nil
            interfaceController.setRootTemplate(makeSignInTemplate(), animated: true, completion: nil)
        }
    }

    func reloadTabContent() {
        contentGeneration += 1
        if let homeTemplate { loadHomeContent(into: homeTemplate) }
        if let artistsTemplate { loadArtists(into: artistsTemplate) }
        if let albumsTemplate { loadAlbums(into: albumsTemplate) }
        if let playlistsTemplate { loadPlaylists(into: playlistsTemplate) }
    }

    func rootSignature() -> String {
        let machine = server?.machineIdentifier ?? "none"
        let library = sectionId ?? "none"
        return "\(machine)|\(library)"
    }

    func startObservingConnection() {
        connectionObservationTask?.cancel()
        connectionObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let manager = AppContext.shared.serverConnection

                self.updateRootTemplate()

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = manager.currentServer
                        _ = manager.currentLibrarySectionId
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.updateRootTemplate()
            }
        }
    }

    // MARK: - Sign In

    func makeSignInTemplate() -> CPListTemplate {
        let item = CPListItem(text: "Sign In to Plex to Start Listening", detailText: "Open Tromme on your iPhone to sign in")
        item.isEnabled = false
        return CPListTemplate(title: "Tromme", sections: [CPListSection(items: [item])])
    }

    // MARK: - Error Helpers

    func makeRetryItem(into template: CPListTemplate, action: @escaping @MainActor () -> Void) -> CPListItem {
        let item = CPListItem(text: "Couldn't Load", detailText: "Tap to retry")
        item.handler = { _, completion in
            action()
            completion()
        }
        return item
    }

    // MARK: - Artwork Loading

    func loadArtwork(path: String?, into item: CPListItem, server: PlexServer, client: PlexAPIClient) {
        guard let url = client.artworkURL(server: server, path: path, width: 300, height: 300) else { return }
        Task {
            guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 300) else { return }
            item.setImage(image)
        }
    }
}
