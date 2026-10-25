import CarPlay
import UIKit

// CarPlay NowPlaying templates.
@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Now Playing

    func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = "Queue"
        nowPlaying.isAlbumArtistButtonEnabled = true

        // Custom buttons, not the system shuffle/repeat ones: those re-read the remote
        // command state on every Now Playing update and flash. These only change when
        // the user changes them.
        let shuffleButton = CPNowPlayingImageButton(image: UIImage(systemName: "shuffle") ?? UIImage()) { [weak self] _ in
            self?.player.toggleShuffle()
        }
        self.shuffleNPButton = shuffleButton

        let modes: [(AudioPlayerService.RepeatMode, String)] = [(.off, "repeat"), (.song, "repeat"), (.once, "repeat.1")]
        repeatNPButtons = Dictionary(uniqueKeysWithValues: modes.map { mode, symbol in
            let button = CPNowPlayingImageButton(image: UIImage(systemName: symbol) ?? UIImage()) { [weak self] _ in
                self?.player.cycleRepeatMode()
            }
            button.isSelected = mode != .off
            return (mode, button)
        })

        let magicMixImage = UIImage(systemName: "wand.and.stars") ?? UIImage()
        let mixBtn = CPNowPlayingImageButton(image: magicMixImage) { [weak self] _ in
            self?.player.requestMagicMixRefill(freshMix: true)
            self?.syncMixButtons()
        }
        self.magicMixButton = mixBtn

        // One button whose selected state marks a favorite. Swapping two buttons via
        // updateNowPlayingButtons() re-sends the whole row and flashes shuffle/repeat.
        let favorite = CPNowPlayingImageButton(image: UIImage(systemName: "star.fill") ?? UIImage()) { [weak self] _ in
            self?.toggleFavorite()
        }
        self.favoriteButton = favorite

        shuffleButton.isSelected = player.isShuffled
        lastPublishedShuffleState = player.isShuffled
        lastPublishedRepeatMode = player.repeatMode
        nowPlaying.updateNowPlayingButtons([shuffleButton, repeatNPButtons[player.repeatMode] ?? repeatNPButtons[.off]!, favorite, mixBtn])
        lastPublishedFavoriteState = false
        syncMixButtons()
    }

    func syncMixButtons() {
        let isMagicMixActive = player.isMagicMixActive
        if lastPublishedMagicMixState != isMagicMixActive {
            lastPublishedMagicMixState = isMagicMixActive
            magicMixButton?.isSelected = isMagicMixActive
        }
        syncFavoriteButton()
    }

    func syncFavoriteButton() {
        currentTrackFavorited = (player.currentTrack?.userRating ?? 0) >= 10
        rebuildNowPlayingButtons()
    }

    func rebuildNowPlayingButtons() {
        if let shuffle = shuffleNPButton, lastPublishedShuffleState != player.isShuffled {
            lastPublishedShuffleState = player.isShuffled
            shuffle.isSelected = player.isShuffled
        }
        if let favorite = favoriteButton, lastPublishedFavoriteState != currentTrackFavorited {
            lastPublishedFavoriteState = currentTrackFavorited
            favorite.isSelected = currentTrackFavorited
        }
        if lastPublishedRepeatMode != player.repeatMode,
           let repeatButton = repeatNPButtons[player.repeatMode],
           let shuffle = shuffleNPButton, let favorite = favoriteButton, let mix = magicMixButton {
            lastPublishedRepeatMode = player.repeatMode
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffle, repeatButton, favorite, mix])
        }
    }

    func toggleFavorite() {
        guard let track = player.currentTrack,
              let server else { return }
        let wasFavorited = currentTrackFavorited
        currentTrackFavorited.toggle()
        rebuildNowPlayingButtons()
        Task {
            let success = await player.setFavorited(!wasFavorited, for: track, server: server, client: client, sectionId: sectionId)
            if !success {
                currentTrackFavorited = wasFavorited
                rebuildNowPlayingButtons()
            }
        }
    }

    func startObservingPlayer() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let p = self.player
                // Read the properties we want to track — withObservationTracking
                // will call onChange when any of them mutate.
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = p.isShuffled
                        _ = p.repeatMode
                        _ = p.isMagicMixActive
                        _ = p.currentTrack
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.syncMixButtons()
            }
        }
    }

    func pushNowPlaying() {
        syncMixButtons()
        let nowPlaying = CPNowPlayingTemplate.shared
        guard interfaceController?.topTemplate !== nowPlaying else { return }
        // Pop to Now Playing if it's already in the stack; otherwise push it fresh.
        interfaceController?.pop(to: nowPlaying, animated: true) { [weak self] success, _ in
            if !success {
                self?.interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
            }
        }
    }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlaySceneDelegate: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard !player.upcomingTracks.isEmpty else { return }
        let tracks = player.upcomingTracks
        let items = tracks.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artistDisplayName)
            item.handler = { [weak self] _, completion in
                self?.player.skipToUpcoming(at: index)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Up Next", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let track = player.currentTrack,
              let albumRatingKey = track.parentRatingKey else { return }
        showAlbumTracks(albumRatingKey: albumRatingKey, albumTitle: track.albumName, artistName: track.artistDisplayName, albumThumb: track.parentThumb)
    }
}
