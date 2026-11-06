import CarPlay
import UIKit

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

        let autoMix = CPNowPlayingImageButton(image: Self.autoMixImage) { _ in
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: AudioPlayerService.autoMixKey), forKey: AudioPlayerService.autoMixKey)
        }
        self.autoMixNPButton = autoMix

        shuffleButton.isSelected = player.isShuffled
        lastPublishedShuffleState = player.isShuffled
        lastPublishedRepeatMode = nil
        lastPublishedMagicMixState = nil
        lastPublishedAutoMixState = nil
        lastPublishedAutoMixEnabled = nil
        lastPublishedAutoMixVisible = nil
        syncMixButtons()
    }

    func syncMixButtons() {
        let isMagicMixActive = player.isMagicMixActive
        if lastPublishedMagicMixState != isMagicMixActive {
            lastPublishedMagicMixState = isMagicMixActive
            magicMixButton?.isSelected = isMagicMixActive
        }
        rebuildNowPlayingButtons()
    }

    func rebuildNowPlayingButtons() {
        if let shuffle = shuffleNPButton, lastPublishedShuffleState != player.isShuffled {
            lastPublishedShuffleState = player.isShuffled
            shuffle.isSelected = player.isShuffled
        }

        let defaults = UserDefaults.standard
        let isAutoMixOn = defaults.bool(forKey: AudioPlayerService.autoMixKey)
        if let autoMix = autoMixNPButton, lastPublishedAutoMixState != isAutoMixOn {
            lastPublishedAutoMixState = isAutoMixOn
            autoMix.isSelected = isAutoMixOn
        }
        let isAutoMixEnabled = !player.isAirPlayConnected
        if let autoMix = autoMixNPButton, lastPublishedAutoMixEnabled != isAutoMixEnabled {
            lastPublishedAutoMixEnabled = isAutoMixEnabled
            autoMix.isEnabled = isAutoMixEnabled
        }

        // Re-sending the row flashes every button, so only do it when its contents change.
        let showsAutoMix = PlusStore.shared.isPlus && defaults.bool(forKey: AudioPlayerService.crossfadeEnabledKey)
        guard lastPublishedRepeatMode != player.repeatMode || lastPublishedAutoMixVisible != showsAutoMix,
              let repeatButton = repeatNPButtons[player.repeatMode],
              let shuffle = shuffleNPButton, let autoMix = autoMixNPButton, let mix = magicMixButton else { return }
        lastPublishedRepeatMode = player.repeatMode
        lastPublishedAutoMixVisible = showsAutoMix
        let buttons: [CPNowPlayingButton] = showsAutoMix ? [shuffle, repeatButton, autoMix, mix] : [shuffle, repeatButton, mix]
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    func startObservingMixSettings() {
        mixSettingsObservationTask?.cancel()
        mixSettingsObservationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                guard !Task.isCancelled, let self else { return }
                self.rebuildNowPlayingButtons()
            }
        }
    }

    private static let autoMixImage: UIImage = {
        let ring: CGFloat = 18
        let lineWidth = ring * 0.13
        let size = CGSize(width: ring * 1.6 + lineWidth, height: ring + lineWidth)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let offset = ring * 0.6
            for x in [lineWidth / 2, lineWidth / 2 + offset] {
                let path = UIBezierPath(ovalIn: CGRect(x: x, y: lineWidth / 2, width: ring, height: ring))
                path.lineWidth = lineWidth
                UIColor.black.setStroke()
                path.stroke()
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()

    func startObservingPlayer() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let p = self.player
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = p.isShuffled
                        _ = p.repeatMode
                        _ = p.isMagicMixActive
                        _ = p.isAirPlayConnected
                        _ = PlusStore.shared.isPlus
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
        showAlbumTracks(albumRatingKey: albumRatingKey, albumTitle: track.albumName)
    }
}
