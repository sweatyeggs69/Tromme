import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    private var server: PlexServer? { AppContext.shared.serverConnection?.currentServer }
    private var sectionId: String? { AppContext.shared.serverConnection?.currentLibrarySectionId }
    private var client: PlexAPIClient? { AppContext.shared.plexClient }
    private var player: AudioPlayerService? { AppContext.shared.audioPlayer }

    private var infiniteButton: CPNowPlayingImageButton?
    private var magicMixButton: CPNowPlayingImageButton?
    private var observationTask: Task<Void, Never>?

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        configureNowPlaying()
        updateRootTemplate()
        startObservingPlayer()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        observationTask?.cancel()
        observationTask = nil
        CPNowPlayingTemplate.shared.remove(self)
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
        }
    }

    private func updateRootTemplate() {
        guard let interfaceController else { return }
        if server != nil, sectionId != nil {
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

            let tabBar = CPTabBarTemplate(templates: [homeList, artistsList, albumsList, playlistsList])
            interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
        } else {
            interfaceController.setRootTemplate(makeSignInTemplate(), animated: true, completion: nil)
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
        Task {
            async let favoritesReq: [PlexMetadata] = client.getFavoriteTracks(server: server, sectionId: sectionId)
            async let recentlyPlayedReq: [PlexMetadata] = client.getRecentlyPlayed(server: server, sectionId: sectionId, limit: 10)
            async let recentlyAddedReq: [PlexMetadata] = client.getRecentlyAdded(server: server, sectionId: sectionId, type: 9, limit: 10)

            let favorites = Array(((try? await favoritesReq) ?? [])
                .sorted { ($0.userRating ?? 0) > ($1.userRating ?? 0) }
                .prefix(10))
            let recentlyPlayed = Array(((try? await recentlyPlayedReq) ?? []).prefix(10))
            let recentlyAdded = Array(((try? await recentlyAddedReq) ?? []).prefix(10))

            var sections: [CPListSection] = []

            // Favorites — menu link
            if !favorites.isEmpty {
                let item = CPListItem(text: "Favorites", detailText: "\(favorites.count) songs")
                item.accessoryType = .disclosureIndicator
                let capturedFavorites = favorites
                item.handler = { [weak self] _, completion in
                    self?.showTrackList(title: "Favorites", tracks: capturedFavorites)
                    completion()
                }
                sections.append(CPListSection(items: [item]))
            }
            
            // Recently Added — image row
            if !recentlyAdded.isEmpty {
                let imageRow = await makeImageRow(
                    title: "Recently Added",
                    items: recentlyAdded,
                    server: server,
                    client: client,
                    onImageSelect: { [weak self] index in
                        let album = recentlyAdded[index]
                        self?.showAlbumTracks(albumRatingKey: album.ratingKey, albumTitle: album.title)
                    },
                    onRowSelect: { [weak self] in
                        self?.showRecentlyAddedList(recentlyAdded)
                    }
                )
                sections.append(CPListSection(items: [imageRow]))
            }

            // Recently Played — image row
            if !recentlyPlayed.isEmpty {
                let imageRow = await makeImageRow(
                    title: "Recently Played",
                    items: recentlyPlayed,
                    server: server,
                    client: client,
                    onImageSelect: { [weak self] index in
                        self?.showTrackList(title: "Recently Played", tracks: recentlyPlayed, startAt: index)
                    },
                    onRowSelect: { [weak self] in
                        self?.showTrackList(title: "Recently Played", tracks: recentlyPlayed)
                    }
                )
                sections.append(CPListSection(items: [imageRow]))
            }

            template.updateSections(sections)
        }
    }

    // MARK: - Artists (A-Z Index)

    private func makeArtistsList() -> CPListTemplate {
        let template = CPListTemplate(title: "Artists", sections: [])
        guard let server, let sectionId, let client else { return template }
        Task {
            let artists = (try? await client.cachedArtists(server: server, sectionId: sectionId)) ?? []
            let letters = alphabetIndex(from: artists, keyPath: \.title)
            let items = letters.map { letter -> CPListItem in
                let count = artists.filter { firstLetter(of: $0.title) == letter }.count
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
        return template
    }

    private func showArtistsForLetter(_ letter: String, allArtists: [PlexMetadata]) {
        let filtered = allArtists
            .filter { firstLetter(of: $0.title) == letter }
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

    // MARK: - Albums (A-Z Index)

    private func makeAlbumsList() -> CPListTemplate {
        let template = CPListTemplate(title: "Albums", sections: [])
        guard let server, let sectionId, let client else { return template }
        Task {
            let albums = (try? await client.cachedAlbums(server: server, sectionId: sectionId)) ?? []
            let letters = alphabetIndex(from: albums, keyPath: \.title)
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
        return template
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
            item.handler = { [weak self] _, completion in
                self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle)
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
        guard let server, let client else { return template }
        Task {
            let playlists = ((try? await client.cachedPlaylists(server: server)) ?? [])
                .filter { $0.isMusicPlaylist }
            let items = playlists.prefix(CPListTemplate.maximumItemCount).map { playlist -> CPListItem in
                let songCount = playlist.leafCount.map { "\($0) songs" }
                let item = CPListItem(text: playlist.title, detailText: songCount)
                item.accessoryType = .disclosureIndicator
                loadArtwork(path: playlist.composite, into: item, server: server, client: client)
                let key = playlist.ratingKey
                let title = playlist.title
                item.handler = { [weak self] _, completion in
                    self?.showPlaylistTracks(playlistKey: key, playlistTitle: title)
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
        }
        return template
    }

    private func showPlaylistTracks(playlistKey: String, playlistTitle: String) {
        guard let server, let client else { return }
        let template = CPListTemplate(title: playlistTitle, sections: [])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            let tracks = (try? await client.cachedPlaylistItems(server: server, playlistKey: playlistKey)) ?? []
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
                let item = CPListItem(text: track.title, detailText: track.artistName)
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

    private func alphabetIndex(from items: [PlexMetadata], keyPath: KeyPath<PlexMetadata, String>) -> [String] {
        var seen = Set<String>()
        var letters: [String] = []
        for item in items {
            let letter = firstLetter(of: item[keyPath: keyPath])
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

        let trackItems = tracks.enumerated().map { index, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artistName)
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
            item.handler = { [weak self] _, completion in
                self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle)
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

    private func showAlbumTracks(albumRatingKey: String, albumTitle: String) {
        guard let server, let client else { return }
        let template = CPListTemplate(title: albumTitle, sections: [])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task {
            let tracks = (try? await client.cachedChildren(server: server, ratingKey: albumRatingKey)) ?? []
            let playableTracks = Array(tracks.filter { $0.type == "track" })
            guard !playableTracks.isEmpty else { return }

            let shuffleItem = CPListItem(text: "Shuffle", detailText: "\(playableTracks.count) songs", image: UIImage(systemName: "shuffle"))
            shuffleItem.handler = { [weak self] _, completion in
                guard let self, let player = self.player else { completion(); return }
                if !player.isShuffled { player.toggleShuffle() }
                player.play(tracks: playableTracks, startingAt: 0)
                self.pushNowPlaying()
                completion()
            }

            let trackItems: [CPListTemplateItem] = playableTracks.prefix(CPListTemplate.maximumItemCount - 1).enumerated().map { index, track -> CPListItem in
                let trackNumber = track.index.map { "\($0). " } ?? ""
                let item = CPListItem(text: "\(trackNumber)\(track.title)", detailText: track.durationFormatted)
                let capturedTracks = playableTracks
                item.handler = { [weak self] _, completion in
                    self?.player?.play(tracks: capturedTracks, startingAt: index)
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

        nowPlaying.updateNowPlayingButtons([shuffleButton, repeatButton, infBtn, mixBtn])
        syncMixButtons()
    }

    private func syncMixButtons() {
        guard let player else { return }
        infiniteButton?.isSelected = player.isInfiniteModeActive
        magicMixButton?.isSelected = player.isMagicMixActive
    }

    private func startObservingPlayer() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                // Read the properties we want to track — withObservationTracking
                // will call onChange when any of them mutate.
                let changed: Void = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = player.isShuffled
                        _ = player.repeatMode
                        _ = player.isInfiniteModeActive
                        _ = player.isMagicMixActive
                    } onChange: {
                        continuation.resume()
                    }
                }
                _ = changed
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

