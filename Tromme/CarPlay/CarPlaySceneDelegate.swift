import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    private var server: PlexServer? { AppContext.shared.serverConnection?.currentServer }
    private var sectionId: String? { AppContext.shared.serverConnection?.currentLibrarySectionId }
    private var client: PlexAPIClient? { AppContext.shared.plexClient }
    private var player: AudioPlayerService? { AppContext.shared.audioPlayer }

    private var shuffleNPButton: CPNowPlayingShuffleButton?
    private var repeatNPButton: CPNowPlayingRepeatButton?
    private var infiniteButton: CPNowPlayingImageButton?
    private var magicMixButton: CPNowPlayingImageButton?
    private var favFilledButton: CPNowPlayingImageButton?
    private var favOutlineButton: CPNowPlayingImageButton?
    private var currentTrackFavorited = false
    private var observationTask: Task<Void, Never>?
    private var connectionObservationTask: Task<Void, Never>?
    private var lastRootSignature: String?
    private var lastServerURI: String?
    private var homeTemplate: CPListTemplate?
    private var artistsTemplate: CPListTemplate?
    private var albumsTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    /// Bumped whenever tab content is (re)loaded so an in-flight load against a
    /// stale connection can't overwrite sections loaded after a reprobe.
    private var contentGeneration = 0

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
        // The persisted server URI may be stale after a period of disconnection
        // (the phone's network changed while the app was suspended). Re-probe so
        // the connection observer can reload tab content against a reachable URI.
        Task { await AppContext.shared.serverConnection?.reprobe() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        observationTask?.cancel()
        observationTask = nil
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
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

    private func updateRootTemplate() {
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
    private func reloadTabContent() {
        contentGeneration += 1
        if let homeTemplate { loadHomeContent(into: homeTemplate) }
        if let artistsTemplate { loadArtists(into: artistsTemplate) }
        if let albumsTemplate { loadAlbums(into: albumsTemplate) }
        if let playlistsTemplate { loadPlaylists(into: playlistsTemplate) }
    }

    private func rootSignature() -> String {
        let machine = server?.machineIdentifier ?? "none"
        let library = sectionId ?? "none"
        return "\(machine)|\(library)"
    }

    private func startObservingConnection() {
        connectionObservationTask?.cancel()
        connectionObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let manager = AppContext.shared.serverConnection else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

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

    private func makeSignInTemplate() -> CPListTemplate {
        let item = CPListItem(text: "Sign In to Plex to Start Listening", detailText: "Open Tromme on your iPhone to sign in")
        item.isEnabled = false
        return CPListTemplate(title: "Tromme", sections: [CPListSection(items: [item])])
    }

    // MARK: - Home

    private func makeHomeList() -> CPListTemplate {
        let template = CPListTemplate(title: "Home", sections: [])
        loadHomeContent(into: template)
        return template
    }

    private func loadHomeContent(into template: CPListTemplate) {
        guard let server, let sectionId, let client else { return }
        let generation = contentGeneration

        // Slots: [0] = Favorites, [1] = Recently Added, [2] = Recently Played
        var slots: [CPListSection?] = [nil, nil, nil]
        var completedCount = 0

        func rebuildSections() {
            completedCount += 1
            guard completedCount == 3 else { return }
            guard generation == self.contentGeneration else { return }
            var sections = slots.compactMap { $0 }
            if sections.isEmpty {
                let retry = makeRetryItem(into: template) { [weak self] in
                    self?.loadHomeContent(into: template)
                }
                sections.append(CPListSection(items: [retry]))
            }
            template.updateSections(sections)
        }

        // Favorites
        Task {
            if let favorites = try? await client.getFavoriteTracks(server: server, sectionId: sectionId),
               !favorites.isEmpty {
                let sorted = Array(favorites
                    .sorted { ($0.userRating ?? 0) > ($1.userRating ?? 0) }
                    .prefix(10))
                let item = CPListItem(text: "Favorites", detailText: "\(sorted.count) songs")
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    self?.showTrackList(title: "Favorites", tracks: sorted)
                    completion()
                }
                slots[0] = CPListSection(items: [item])
            }
            rebuildSections()
        }

        // Recently Added
        Task {
            if let recentlyAdded = try? await client.getRecentlyAdded(server: server, sectionId: sectionId, type: 9, limit: 10),
               !recentlyAdded.isEmpty {
                let limited = Array(recentlyAdded.prefix(10))
                let imageRow = await makeImageRow(
                    title: "Recently Added",
                    items: limited,
                    server: server,
                    client: client,
                    onImageSelect: { [weak self] index in
                        let album = limited[index]
                        self?.showAlbumTracks(albumRatingKey: album.ratingKey, albumTitle: album.title, albumThumb: album.thumb)
                    },
                    onRowSelect: { [weak self] in
                        self?.showRecentlyAddedList(limited)
                    }
                )
                slots[1] = CPListSection(items: [imageRow])
            }
            rebuildSections()
        }

        // Recently Played
        Task {
            if let recentlyPlayed = try? await client.getRecentlyPlayed(server: server, sectionId: sectionId, limit: 10),
               !recentlyPlayed.isEmpty {
                let limited = Array(recentlyPlayed.prefix(10))
                let imageRow = await makeImageRow(
                    title: "Recently Played",
                    items: limited,
                    server: server,
                    client: client,
                    onImageSelect: { [weak self] index in
                        self?.showTrackList(title: "Recently Played", tracks: limited, startAt: index)
                    },
                    onRowSelect: { [weak self] in
                        self?.showTrackList(title: "Recently Played", tracks: limited)
                    }
                )
                slots[2] = CPListSection(items: [imageRow])
            }
            rebuildSections()
        }
    }

    // MARK: - Artists (A-Z Index)

    private func makeArtistsList() -> CPListTemplate {
        let template = CPListTemplate(title: "Artists", sections: [])
        loadArtists(into: template)
        return template
    }

    private func loadArtists(into template: CPListTemplate) {
        guard let server, let sectionId, let client else { return }
        let generation = contentGeneration
        Task {
            let artists: [PlexMetadata]
            do {
                artists = try await client.cachedArtists(server: server, sectionId: sectionId)
            } catch {
                guard generation == contentGeneration else { return }
                let retry = makeRetryItem(into: template) { [weak self] in
                    self?.loadArtists(into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            guard generation == contentGeneration else { return }
            populateArtists(artists, into: template)
        }
    }

    private func populateArtists(_ artists: [PlexMetadata], into template: CPListTemplate) {
        let letters = alphabetIndex(from: artists) { artist in
            artist.titleSort ?? artist.title
        }
        let items = letters.map { letter -> CPListItem in
            let count = artists.filter { firstLetter(of: $0.titleSort ?? $0.title) == letter }.count
            let item = CPListItem(text: letter, detailText: "\(count) artists")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showArtistsForLetter(letter, allArtists: artists)
                completion()
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
    }

    private func showArtistsForLetter(_ letter: String, allArtists: [PlexMetadata]) {
        let filtered = allArtists
            .filter { firstLetter(of: $0.titleSort ?? $0.title) == letter }
            .sorted { ($0.titleSort ?? $0.title).localizedCaseInsensitiveCompare($1.titleSort ?? $1.title) == .orderedAscending }
        let items = filtered.prefix(CPListTemplate.maximumItemCount).map { artist -> CPListItem in
            let item = CPListItem(text: artist.title, detailText: nil)
            item.accessoryType = .disclosureIndicator
            let ratingKey = artist.ratingKey
            let name = artist.title
            item.handler = { [weak self] _, completion in
                self?.showArtistAlbums(artistRatingKey: ratingKey, artistName: name)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: letter, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showArtistAlbums(artistRatingKey: String, artistName: String) {
        guard let server, let client else { return }
        let template = CPListTemplate(title: artistName, sections: [])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        loadArtistAlbums(artistRatingKey: artistRatingKey, server: server, client: client, into: template)
    }

    private func loadArtistAlbums(artistRatingKey: String, server: PlexServer, client: PlexAPIClient, into template: CPListTemplate) {
        Task {
            let children: [PlexMetadata]
            do {
                children = try await client.cachedChildren(server: server, ratingKey: artistRatingKey)
            } catch {
                let retry = makeRetryItem(into: template) { [weak self] in
                    self?.loadArtistAlbums(artistRatingKey: artistRatingKey, server: server, client: client, into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            let albums = children.filter { $0.type == "album" }
            guard !albums.isEmpty else {
                template.updateSections([])
                return
            }

            let shuffleItem = CPListItem(text: "Shuffle", detailText: "\(albums.count) albums", image: UIImage(systemName: "shuffle"))
            shuffleItem.handler = { [weak self] _, completion in
                Task {
                    let allTracks = await withTaskGroup(of: [PlexMetadata].self) { group in
                        for album in albums {
                            let key = album.ratingKey
                            group.addTask {
                                do {
                                    return try await client.cachedChildren(server: server, ratingKey: key)
                                } catch {
                                    #if DEBUG
                                    print("[CarPlay] Failed to load tracks for album \(key): \(error)")
                                    #endif
                                    return []
                                }
                            }
                        }
                        var result: [PlexMetadata] = []
                        for await tracks in group {
                            result.append(contentsOf: tracks.filter { $0.type == "track" })
                        }
                        return result
                    }
                    guard !allTracks.isEmpty, let self, let player = self.player else {
                        completion()
                        return
                    }
                    if !player.isShuffled { player.toggleShuffle() }
                    player.play(tracks: allTracks, startingAt: 0)
                    self.pushNowPlaying()
                    completion()
                }
            }

            let albumItems: [CPListTemplateItem] = albums.prefix(CPListTemplate.maximumItemCount - 1).map { album -> CPListItem in
                let item = CPListItem(text: album.title, detailText: album.releaseYear)
                item.accessoryType = .disclosureIndicator
                loadArtwork(path: album.thumb, into: item, server: server, client: client)
                let ratingKey = album.ratingKey
                let albumTitle = album.title
                let albumThumb = album.thumb
                let albumYear = album.releaseYear
                item.handler = { [weak self] _, completion in
                    self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle, albumThumb: albumThumb, releaseYear: albumYear)
                    completion()
                }
                return item
            }

            var allItems: [CPListTemplateItem] = [shuffleItem]
            allItems.append(contentsOf: albumItems)
            template.updateSections([CPListSection(items: allItems)])
        }
    }

    // MARK: - Albums (A-Z Index)

    private func makeAlbumsList() -> CPListTemplate {
        let template = CPListTemplate(title: "Albums", sections: [])
        loadAlbums(into: template)
        return template
    }

    private func loadAlbums(into template: CPListTemplate) {
        guard let server, let sectionId, let client else { return }
        let generation = contentGeneration
        Task {
            let albums: [PlexMetadata]
            do {
                albums = try await client.cachedAlbums(server: server, sectionId: sectionId)
            } catch {
                guard generation == contentGeneration else { return }
                let retry = makeRetryItem(into: template) { [weak self] in
                    self?.loadAlbums(into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            guard generation == contentGeneration else { return }
            populateAlbums(albums, into: template)
        }
    }

    private func populateAlbums(_ albums: [PlexMetadata], into template: CPListTemplate) {
        let letters = alphabetIndex(from: albums) { $0.title }
        let items = letters.map { letter -> CPListItem in
            let count = albums.filter { firstLetter(of: $0.title) == letter }.count
            let item = CPListItem(text: letter, detailText: "\(count) albums")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showAlbumsForLetter(letter, allAlbums: albums)
                completion()
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
    }

    private func showAlbumsForLetter(_ letter: String, allAlbums: [PlexMetadata]) {
        let filtered = allAlbums
            .filter { firstLetter(of: $0.title) == letter }
            .sorted { ($0.titleSort ?? $0.title).localizedCaseInsensitiveCompare($1.titleSort ?? $1.title) == .orderedAscending }
        guard let server, let client else { return }
        let items = filtered.prefix(CPListTemplate.maximumItemCount).map { album -> CPListItem in
            let item = CPListItem(text: album.title, detailText: album.parentTitle ?? "")
            item.accessoryType = .disclosureIndicator
            loadArtwork(path: album.thumb, into: item, server: server, client: client)
            let ratingKey = album.ratingKey
            let albumTitle = album.title
            let albumThumb = album.thumb
            let albumYear = album.releaseYear
            item.handler = { [weak self] _, completion in
                self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle, albumThumb: albumThumb, releaseYear: albumYear)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: letter, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Playlists

    private func makePlaylistsList() -> CPListTemplate {
        let template = CPListTemplate(title: "Playlists", sections: [])
        loadPlaylists(into: template)
        return template
    }

    private func loadPlaylists(into template: CPListTemplate) {
        guard let server, let client else { return }
        let generation = contentGeneration
        Task {
            let playlists: [PlexPlaylist]
            do {
                playlists = try await client.cachedPlaylists(server: server)
            } catch {
                guard generation == contentGeneration else { return }
                let retry = makeRetryItem(into: template) { [weak self] in
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
                item.handler = { [weak self] _, completion in
                    self?.showPlaylistTracks(playlistKey: key, playlistTitle: title)
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
        loadPlaylistTracks(playlistKey: playlistKey, server: server, client: client, into: template)
    }

    private func loadPlaylistTracks(playlistKey: String, server: PlexServer, client: PlexAPIClient, into template: CPListTemplate) {
        Task {
            let tracks: [PlexMetadata]
            do {
                tracks = try await client.cachedPlaylistItems(server: server, playlistKey: playlistKey)
            } catch {
                let retry = makeRetryItem(into: template) { [weak self] in
                    self?.loadPlaylistTracks(playlistKey: playlistKey, server: server, client: client, into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            guard !tracks.isEmpty else { return }

            let shuffleItem = CPListItem(text: "Shuffle", detailText: "\(tracks.count) songs", image: UIImage(systemName: "shuffle"))
            shuffleItem.handler = { [weak self] _, completion in
                guard let self, let player = self.player else { completion(); return }
                if !player.isShuffled { player.toggleShuffle() }
                player.play(tracks: tracks, startingAt: 0)
                self.pushNowPlaying()
                completion()
            }

            let trackItems: [CPListTemplateItem] = tracks.prefix(CPListTemplate.maximumItemCount - 1).enumerated().map { index, track -> CPListItem in
                let item = CPListItem(text: track.title, detailText: track.artistDisplayName)
                loadArtwork(path: track.thumb ?? track.parentThumb, into: item, server: server, client: client)
                item.handler = { [weak self] _, completion in
                    self?.player?.play(tracks: tracks, startingAt: index)
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

    // MARK: - Alphabet Helpers

    private func firstLetter(of title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return "#" }
        if CharacterSet.letters.contains(first) {
            return String(trimmed.prefix(1)).uppercased()
        }
        return "#"
    }

    private func alphabetIndex(
        from items: [PlexMetadata],
        titleProvider: (PlexMetadata) -> String
    ) -> [String] {
        var seen = Set<String>()
        var letters: [String] = []
        for item in items {
            let letter = firstLetter(of: titleProvider(item))
            if seen.insert(letter).inserted {
                letters.append(letter)
            }
        }
        return letters.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
    }

    // MARK: - Track List (with Shuffle)

    private func showTrackList(title: String, tracks: [PlexMetadata], startAt: Int? = nil) {
        let shuffleItem = CPListItem(text: "Shuffle", detailText: "\(tracks.count) songs", image: UIImage(systemName: "shuffle"))
        let capturedTracks = tracks
        shuffleItem.handler = { [weak self] _, completion in
            guard let self, let player = self.player else { completion(); return }
            if !player.isShuffled { player.toggleShuffle() }
            player.play(tracks: capturedTracks, startingAt: 0)
            self.pushNowPlaying()
            completion()
        }

        let trackItems: [CPListTemplateItem] = tracks.prefix(CPListTemplate.maximumItemCount - 1).enumerated().map { index, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artistDisplayName)
            if let server, let client {
                loadArtwork(path: track.thumb ?? track.parentThumb, into: item, server: server, client: client)
            }
            item.handler = { [weak self] _, completion in
                self?.player?.play(tracks: capturedTracks, startingAt: index)
                self?.pushNowPlaying()
                completion()
            }
            return item
        }

        var allItems: [CPListTemplateItem] = [shuffleItem]
        allItems.append(contentsOf: trackItems)
        let template = CPListTemplate(title: title, sections: [CPListSection(items: allItems)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        // If called from an image row tap, auto-play that track
        if let startAt {
            player?.play(tracks: tracks, startingAt: startAt)
            pushNowPlaying()
        }
    }

    // MARK: - Recently Added List

    private func showRecentlyAddedList(_ albums: [PlexMetadata]) {
        guard let server, let client else { return }
        let items = albums.map { album -> CPListItem in
            let item = CPListItem(text: album.title, detailText: album.parentTitle ?? "")
            item.accessoryType = .disclosureIndicator
            loadArtwork(path: album.thumb, into: item, server: server, client: client)
            let ratingKey = album.ratingKey
            let albumTitle = album.title
            let albumThumb = album.thumb
            let albumYear = album.releaseYear
            item.handler = { [weak self] _, completion in
                self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle, albumThumb: albumThumb, releaseYear: albumYear)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Recently Added", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Image Row

    private func makeImageRow(
        title: String,
        items: [PlexMetadata],
        server: PlexServer,
        client: PlexAPIClient,
        onImageSelect: @escaping @MainActor (Int) -> Void,
        onRowSelect: @escaping @MainActor () -> Void
    ) async -> CPListImageRowItem {
        let maxImages = CPMaximumNumberOfGridImages
        let limited = Array(items.prefix(maxImages))
        let placeholder = UIImage(systemName: "music.note") ?? UIImage()

        // Load artwork in parallel
        var loadedImages: [Int: UIImage] = [:]
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (i, metadata) in limited.enumerated() {
                let thumbPath = metadata.thumb ?? metadata.parentThumb
                group.addTask {
                    guard let url = client.artworkURL(server: server, path: thumbPath, width: 300, height: 300) else {
                        return (i, nil)
                    }
                    return (i, await ImageCache.shared.image(for: url, targetPixelSize: 300))
                }
            }
            for await (i, img) in group {
                if let img { loadedImages[i] = img }
            }
        }

        let elements = limited.enumerated().map { i, _ -> CPListImageRowItemRowElement in
            CPListImageRowItemRowElement(image: loadedImages[i] ?? placeholder, title: nil, subtitle: nil)
        }

        let row = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
        row.listImageRowHandler = { _, index, completion in
            onImageSelect(index)
            completion()
        }
        row.handler = { _, completion in
            onRowSelect()
            completion()
        }

        return row
    }

    // MARK: - Album Tracks

    private func showAlbumTracks(albumRatingKey: String, albumTitle: String, albumThumb: String? = nil, releaseYear: String? = nil) {
        guard let server, let client else { return }
        Task {
            // Load tracks and artwork in parallel
            let artworkTask = Task<UIImage?, Never> {
                guard let path = albumThumb,
                      let url = client.artworkURL(server: server, path: path, width: 300, height: 300) else { return nil }
                return await ImageCache.shared.image(for: url, targetPixelSize: 300)
            }

            let children: [PlexMetadata]
            do {
                children = try await client.cachedChildren(server: server, ratingKey: albumRatingKey)
            } catch {
                let errItem = CPListItem(text: "Couldn't Load", detailText: "Go back and try again")
                errItem.isEnabled = false
                let errTemplate = CPListTemplate(title: nil, sections: [CPListSection(items: [errItem])])
                interfaceController?.pushTemplate(errTemplate, animated: true, completion: nil)
                return
            }

            let artworkImage = await artworkTask.value
            let playableTracks = Array(children.filter { $0.type == "track" })
            guard !playableTracks.isEmpty else { return }

            let artistName = playableTracks.first?.grandparentTitle ?? playableTracks.first?.parentTitle
            let subtitleParts = [artistName, releaseYear].compactMap { $0 }
            let subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")

            let thumbnail = CPThumbnailImage(image: artworkImage ?? (UIImage(systemName: "music.note") ?? UIImage()))

            let playBtn = CPButton(image: UIImage(systemName: "play.fill") ?? UIImage()) { [weak self] _ in
                guard let self, let player = self.player else { return }
                if player.isShuffled { player.toggleShuffle() }
                player.play(tracks: playableTracks, startingAt: 0)
                self.pushNowPlaying()
            }
            playBtn.title = "Play"

            let shuffleBtn = CPButton(image: UIImage(systemName: "shuffle") ?? UIImage()) { [weak self] _ in
                guard let self, let player = self.player else { return }
                if !player.isShuffled { player.toggleShuffle() }
                player.play(tracks: playableTracks, startingAt: 0)
                self.pushNowPlaying()
            }

            let detailsHeader = CPListTemplateDetailsHeader(
                thumbnail: thumbnail,
                title: albumTitle,
                subtitle: subtitle,
                actionButtons: [playBtn, shuffleBtn]
            )

            let trackItems: [CPListTemplateItem] = playableTracks
                .prefix(CPListTemplate.maximumItemCount)
                .enumerated()
                .map { index, track -> CPListItem in
                    let star = (track.userRating ?? 0) >= 4 ? "⭑ " : ""
                    let prefix = track.index.map { "\($0) " } ?? ""
                    let item = CPListItem(text: "\(star)\(prefix)\(track.title)", detailText: nil)
                    let capturedTracks = playableTracks
                    item.handler = { [weak self] _, completion in
                        self?.player?.play(tracks: capturedTracks, startingAt: index)
                        self?.pushNowPlaying()
                        completion()
                    }
                    return item
                }

            let queueBarBtn = CPBarButton(image: UIImage(systemName: "text.badge.plus") ?? UIImage()) { [weak self] _ in
                guard let player = self?.player else { return }
                for track in playableTracks { player.addToEndOfQueue(track) }
            }

            let template = CPListTemplate(
                title: nil,
                listHeader: detailsHeader,
                sections: [CPListSection(items: trackItems)],
                assistantCellConfiguration: nil
            )
            template.trailingNavigationBarButtons = [queueBarBtn]
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
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
        self.shuffleNPButton = shuffleButton

        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            self?.player?.cycleRepeatMode()
        }
        self.repeatNPButton = repeatButton

        let infiniteImage = UIImage(systemName: "infinity") ?? UIImage()
        let infBtn = CPNowPlayingImageButton(image: infiniteImage) { [weak self] _ in
            guard let player = self?.player else { return }
            if player.isInfiniteModeActive {
                player.isInfiniteModeActive = false
            } else {
                player.isMagicMixActive = false
                player.isInfiniteModeActive = true
            }
            self?.syncMixButtons()
        }
        self.infiniteButton = infBtn

        let magicMixImage = UIImage(systemName: "wand.and.stars") ?? UIImage()
        let mixBtn = CPNowPlayingImageButton(image: magicMixImage) { [weak self] _ in
            guard let player = self?.player else { return }
            if player.isMagicMixActive {
                player.isMagicMixActive = false
            } else {
                player.isInfiniteModeActive = false
                player.isMagicMixActive = true
            }
            self?.syncMixButtons()
        }
        self.magicMixButton = mixBtn

        let filled = CPNowPlayingImageButton(image: UIImage(systemName: "star.fill") ?? UIImage()) { [weak self] _ in
            self?.toggleFavorite()
        }
        self.favFilledButton = filled

        let outline = CPNowPlayingImageButton(image: UIImage(systemName: "star") ?? UIImage()) { [weak self] _ in
            self?.toggleFavorite()
        }
        self.favOutlineButton = outline

        nowPlaying.updateNowPlayingButtons([shuffleButton, repeatButton, outline, infBtn, mixBtn])
        syncMixButtons()
    }

    private func syncMixButtons() {
        guard let player else { return }
        infiniteButton?.isSelected = player.isInfiniteModeActive
        magicMixButton?.isSelected = player.isMagicMixActive
        syncFavoriteButton()
    }

    private func syncFavoriteButton() {
        currentTrackFavorited = (player?.currentTrack?.userRating ?? 0) >= 4
        rebuildNowPlayingButtons()
    }

    private func rebuildNowPlayingButtons() {
        guard let s = shuffleNPButton, let r = repeatNPButton,
              let inf = infiniteButton, let mix = magicMixButton,
              let filled = favFilledButton, let outline = favOutlineButton else { return }
        let fav = currentTrackFavorited ? filled : outline
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([s, r, fav, inf, mix])
    }

    private func toggleFavorite() {
        guard let player, let track = player.currentTrack,
              let server, let client else { return }
        currentTrackFavorited.toggle()
        rebuildNowPlayingButtons()
        let newRating = currentTrackFavorited ? 10 : 0
        Task {
            try? await client.rateItem(server: server, ratingKey: track.ratingKey, rating: newRating)
        }
    }

    private func startObservingPlayer() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                // Read the properties we want to track — withObservationTracking
                // will call onChange when any of them mutate.
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = player.isShuffled
                        _ = player.repeatMode
                        _ = player.isInfiniteModeActive
                        _ = player.isMagicMixActive
                        _ = player.currentTrack
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.syncMixButtons()
            }
        }
    }

    private func pushNowPlaying() {
        syncMixButtons()
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController?.topTemplate !== nowPlaying {
            interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: - Error Helpers

    private func makeRetryItem(into template: CPListTemplate, action: @escaping @MainActor () -> Void) -> CPListItem {
        let item = CPListItem(text: "Couldn't Load", detailText: "Tap to retry")
        item.handler = { _, completion in
            action()
            completion()
        }
        return item
    }

    // MARK: - Artwork Loading

    private func loadArtwork(path: String?, into item: CPListItem, server: PlexServer, client: PlexAPIClient) {
        guard let url = client.artworkURL(server: server, path: path, width: 300, height: 300) else { return }
        Task {
            guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 300) else { return }
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
            let item = CPListItem(text: track.title, detailText: track.artistDisplayName)
            item.handler = { [weak self] _, completion in
                self?.player?.skipToUpcoming(at: index)
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
        showAlbumTracks(albumRatingKey: albumRatingKey, albumTitle: track.albumName, albumThumb: track.parentThumb)
    }
}
