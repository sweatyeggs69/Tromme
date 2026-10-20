import AVFoundation
import MediaPlayer
import Network
import Observation

// Now Playing info and remote commands.
extension AudioPlayerService {
    // MARK: - Now Playing Info & Remote Commands

    func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.playCurrent()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pauseCurrent()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
            }
            return .success
        }
        // Press-and-hold on the CarPlay / lock screen skip buttons.
        center.seekForwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSeekCommandEvent else { return .commandFailed }
            switch event.type {
            case .beginSeeking: self.beginHeldSeek(forward: true)
            case .endSeeking: self.endHeldSeek()
            @unknown default: break
            }
            return .success
        }
        center.seekBackwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSeekCommandEvent else { return .commandFailed }
            switch event.type {
            case .beginSeeking: self.beginHeldSeek(forward: false)
            case .endSeeking: self.endHeldSeek()
            @unknown default: break
            }
            return .success
        }
        center.changeShuffleModeCommand.isEnabled = true
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let wantsShuffle = event.shuffleType != .off
            if wantsShuffle != self.isShuffled { self.toggleShuffle() }
            return .success
        }
        center.changeRepeatModeCommand.isEnabled = true
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            switch event.repeatType {
            // Mapped so the system repeat / repeat.1 icons match the in-app ones.
            case .off: self.repeatMode = .off
            case .all: self.repeatMode = .song
            case .one: self.repeatMode = .once
            @unknown default: break
            }
            self.savePlaybackState()
            self.updateShuffleRepeatState()
            return .success
        }
        center.likeCommand.isEnabled = true
        center.likeCommand.addTarget { [weak self] _ in
            guard let self, let track = self.currentTrack,
                  let server = self.server, let client = self.client else { return .commandFailed }
            let wasFavorited = (track.userRating ?? 0) >= 10
            let sectionId = AppContext.shared.serverConnection.currentLibrarySectionId
            Task {
                await self.setFavorited(!wasFavorited, for: track, server: server, client: client, sectionId: sectionId)
            }
            return .success
        }
        updateShuffleRepeatState()
    }

    func updateShuffleRepeatState() {
        let center = MPRemoteCommandCenter.shared()
        let shuffleType: MPShuffleType = isShuffled ? .items : .off
        if center.changeShuffleModeCommand.currentShuffleType != shuffleType {
            center.changeShuffleModeCommand.currentShuffleType = shuffleType
        }
        let repeatType: MPRepeatType
        switch repeatMode {
        case .off: repeatType = .off
        case .song: repeatType = .all
        case .once: repeatType = .one
        }
        if center.changeRepeatModeCommand.currentRepeatType != repeatType {
            center.changeRepeatModeCommand.currentRepeatType = repeatType
        }
    }

    /// Only writes when the state changes; re-setting the same value still makes CarPlay redraw its buttons.
    func setLikeCommandActive(_ active: Bool) {
        let command = MPRemoteCommandCenter.shared().likeCommand
        if command.isActive != active { command.isActive = active }
    }

    func resolvedPlaybackPath(for server: PlexServer) -> PlaybackPath {
        if isCellular {
            return .cellular
        }
        if let activeConnection = server.connections.first(where: { $0.uri == server.uri }) {
            if activeConnection.relay == true {
                return .relay
            }
            return activeConnection.local == true ? .lan : .wan
        }
        return .wan
    }

    func updateNowPlayingInfo() {
        guard let currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            lastPublishedNowPlayingTrackKey = nil
            cachedArtwork = nil
            cachedArtworkThumbPath = nil
            nowPlayingArtworkTask?.cancel()
            nowPlayingArtworkTask = nil
            NowPlayingAnimatedArtwork.shared.clear()
            return
        }

        let trackKey = currentTrack.ratingKey

        if trackKey == lastPublishedNowPlayingTrackKey,
           !NowPlayingAnimatedArtwork.shared.needsUpdate(for: currentTrack),
           var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            // Every write makes CarPlay refresh its whole transport row (play/pause,
            // shuffle, repeat), so skip writes that wouldn't change anything.
            let rate = isPlaying ? 1.0 : 0.0
            let publishedRate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double
            let publishedDuration = info[MPMediaItemPropertyPlaybackDuration] as? Double
            let publishedElapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
            if publishedRate == rate,
               let publishedDuration, abs(publishedDuration - duration) < 0.5,
               let publishedElapsed {
                let expected = publishedElapsed + rate * Date().timeIntervalSince(lastPublishedNowPlayingDate)
                if abs(expected - currentTime) < 1.5 { return }
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            info[MPMediaItemPropertyPlaybackDuration] = duration
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            lastPublishedNowPlayingDate = Date()
            return
        }

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTrack.title
        info[MPMediaItemPropertyArtist] = currentTrack.artistDisplayName
        info[MPMediaItemPropertyAlbumTitle] = currentTrack.albumName
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        }
        info.merge(NowPlayingAnimatedArtwork.shared.entries(for: currentTrack)) { _, new in new }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastPublishedNowPlayingDate = Date()
        setLikeCommandActive((currentTrack.userRating ?? 0) >= 10)
        lastPublishedNowPlayingTrackKey = trackKey

        let thumbPath = currentTrack.thumb ?? currentTrack.parentThumb
        prepareAnimatedArtwork(for: currentTrack, thumbPath: thumbPath)
        if thumbPath != cachedArtworkThumbPath {
            cachedArtworkThumbPath = thumbPath
            cachedArtwork = nil
            nowPlayingArtworkTask?.cancel()
            if let client, let server,
               let url = client.artworkURL(server: server, path: thumbPath, width: ArtworkView.maxTranscodePx, height: ArtworkView.maxTranscodePx) {
                let generation = playbackGeneration
                let capturedTrackKey = trackKey
                nowPlayingArtworkTask = Task {
                    guard let image = await ImageCache.shared.image(for: url, targetPixelSize: ArtworkView.maxTranscodePx) else { return }
                    guard !Task.isCancelled else { return }
                    guard self.playbackGeneration == generation else { return }
                    guard self.currentTrack?.ratingKey == capturedTrackKey else { return }
                    let artwork = Self.makeArtwork(from: image)
                    self.cachedArtwork = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
                }
            }
        }
    }

    /// Tromme+ animated artwork for the lock screen; merged into the Now Playing info
    /// once the album's lookup comes back. The static artwork is its preview image.
    private func prepareAnimatedArtwork(for track: PlexMetadata, thumbPath: String?) {
        let pixelSize = ArtworkView.maxTranscodePx
        let previewURL = client.flatMap { client in
            server.flatMap { client.artworkURL(server: $0, path: thumbPath, width: pixelSize, height: pixelSize) }
        }
        NowPlayingAnimatedArtwork.shared.prepare(for: track) { _ in
            guard let previewURL else { return nil }
            return await ImageCache.shared.image(for: previewURL, targetPixelSize: pixelSize)
        } apply: { entries in
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            info.merge(entries) { _, new in new }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
