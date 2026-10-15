import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    var server: PlexServer? { AppContext.shared.serverConnection.currentServer }
    var sectionId: String? { AppContext.shared.serverConnection.currentLibrarySectionId }
    var client: PlexAPIClient { AppContext.shared.plexClient }
    var player: AudioPlayerService { AppContext.shared.audioPlayer }

    var shuffleNPButton: CPNowPlayingShuffleButton?
    var repeatNPButton: CPNowPlayingRepeatButton?
    var magicMixButton: CPNowPlayingImageButton?
    var favFilledButton: CPNowPlayingImageButton?
    var favOutlineButton: CPNowPlayingImageButton?
    var currentTrackFavorited = false
    /// Last favorited state actually pushed to `CPNowPlayingTemplate`. Several
    /// listeners (pushNowPlaying, the player-state observation loop) react to
    /// the same track-change event and each call rebuildNowPlayingButtons();
    /// without this guard they redundantly re-call updateNowPlayingButtons()
    /// with an unchanged value, and each call flashes the whole button row
    /// (shuffle included) as CarPlay redraws it.
    var lastPublishedFavoriteState: Bool?
    /// Last Magic Mix state actually pushed to `magicMixButton.isSelected`.
    /// `syncMixButtons()` runs on every track change (currentTrack is one of
    /// the tracked properties in the player observation loop), and `isSelected`
    /// is a remote property on a CarPlay-rendered button — setting it, even to
    /// its current value, is a real round-trip that visibly redraws the whole
    /// button row (shuffle included), same as the unguarded favorite rebuild.
    var lastPublishedMagicMixState: Bool?
    var observationTask: Task<Void, Never>?
    var connectionObservationTask: Task<Void, Never>?
    var recentlyPlayedObservationTask: Task<Void, Never>?
    var favoritesObservationTask: Task<Void, Never>?
    /// Slots: [0] = Favorites, [1] = Recently Added, [2] = Recently Played.
    /// Persisted so the favorites/recently-played observers can each patch
    /// their own slot without losing the other sections already on screen.
    var homeSections: [CPListSection?] = [nil, nil, nil]
    var lastRootSignature: String?
    var lastServerURI: String?
    var homeTemplate: CPListTemplate?
    var artistsTemplate: CPListTemplate?
    var albumsTemplate: CPListTemplate?
    var playlistsTemplate: CPListTemplate?
    /// Bumped whenever tab content is (re)loaded so an in-flight load against a
    /// stale connection can't overwrite sections loaded after a reprobe.
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
        // The persisted server URI may be stale after a period of disconnection
        // (the phone's network changed while the app was suspended). Re-probe so
        // the connection observer can reload tab content against a reachable URI.
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
            // Same server and library. If the reachable connection URI changed
            // (e.g. a reprobe after reconnecting on a different network), reload
            // tab content in place instead of resetting the template stack.
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

    /// Re-fetches the content of all four tabs against the current server
    /// connection without replacing the root template (which would pop any
    /// pushed templates, including Now Playing).
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

                // Reconcile any state that was set between polling iterations,
                // before the observer below was installed.
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
