import AVFoundation
import MediaPlayer
import Network
import Observation

// Track end and advance handling.
extension AudioPlayerService {
    // MARK: - Track End

    func observePlayerState() {
        timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let status = observedPlayer.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Discard stale callbacks from a previous player that fired just
                // before tearDownObservers() could cancel them. Without this guard,
                // a queued Task from the old player's .paused transition can set
                // isPlaying = false momentarily after the new player has started,
                // causing the play/pause button to flicker on track transitions.
                guard observedPlayer === self.player else { return }
                let waitingForPlayback = status == .waitingToPlayAtSpecifiedRate
                // Preserve the current "playing intent" while AVPlayer is briefly
                // buffering so transport controls do not flicker.
                // actionAtItemEnd = .pause makes AVPlayer pause itself when a track
                // finishes, just before didPlayToEndTime advances the queue. That's
                // not a user pause, so keep the playing state instead of briefly
                // publishing rate 0 (which flashes Play on CarPlay / lock screen).
                let pausedAtItemEnd = status == .paused && self.playbackIntent && !self.isSeeking
                    && Self.hasReachedEnd(observedPlayer.currentItem)
                let playing = status == .playing || ((waitingForPlayback || pausedAtItemEnd) && self.isPlaying)
                #if DEBUG
                if self.lastLoggedTimeControlStatus != status {
                    self.lastLoggedTimeControlStatus = status
                    self.logPlayback("time_control", "status=\(status.rawValue)")
                }
                #endif
                guard playing != self.isPlaying else { return }
                self.isPlaying = playing
                self.updateNowPlayingInfo()
            }
        }
    }

    /// A new track occasionally lands paused while the user still wants playback (the
    /// player pausing itself at an item boundary, a transient audio session hiccup).
    /// Nothing else restarts it, so nudge it once the item has had time to load.
    func watchForStalledStart() {
        let generation = playbackGeneration
        Task { @MainActor [weak self] in
            for delay in [1.5, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.playbackGeneration == generation else { return }
                // A gapless item that failed while it was still queued never fires the
                // status observer registered after the advance, so recover it here.
                if self.playbackIntent, self.player?.currentItem?.status == .failed {
                    self.logPlayback("stalled_start_item_failed")
                    self.handlePlaybackFailure("preloaded_item_failed")
                    return
                }
                guard self.playbackIntent, !self.isSeeking,
                      let player = self.player, let item = player.currentItem,
                      item.status == .readyToPlay, player.timeControlStatus == .paused,
                      !Self.hasReachedEnd(item) else { continue }
                self.logPlayback("stalled_start_nudge")
                self.wasInterruptedWhilePlaying = false
                try? await self.activateAudioSession()
                player.play()
                if !self.isPlaying {
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    static func hasReachedEnd(_ item: AVPlayerItem?) -> Bool {
        guard let item, item.status == .readyToPlay else { return false }
        let itemDuration = item.duration.seconds
        guard itemDuration.isFinite, itemDuration > 0 else { return false }
        return CMTimeGetSeconds(item.currentTime()) >= itemDuration - 0.5
    }

    func observeQueueAdvance() {
        currentItemObservation = player?.observe(\.currentItem, options: [.new]) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self] in
                guard let self, observedPlayer === self.player,
                      let preloaded = self.preloadedNext else { return }
                if observedPlayer.currentItem === preloaded.item {
                    self.advanceToPreloadedTrack(preloaded)
                } else if observedPlayer.currentItem == nil {
                    // The enqueued item failed and AVQueuePlayer skipped past it.
                    self.logPlayback("gapless_advance_failed", "track=\(preloaded.ratingKey)")
                    self.discardPreloadedNext()
                    self.next()
                }
            }
        }
    }

    func observeTrackEnd(_ item: AVPlayerItem) {
        if let trackEndObserver {
            NotificationCenter.default.removeObserver(trackEndObserver)
            self.trackEndObserver = nil
        }
        trackEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTrackEnd()
            }
        }
    }

    func handleTrackEnd() {
        // With a gapless item enqueued, AVQueuePlayer advances on any real
        // end-of-item — including the seek races suppressed below. The
        // currentItem observer moves app state over; this notification can
        // arrive before the advance, so only act here if it already happened.
        if let preloaded = preloadedNext, player?.items().contains(preloaded.item) == true {
            if player?.currentItem === preloaded.item {
                advanceToPreloadedTrack(preloaded)
            }
            return
        }
        // A zero-tolerance seek on a local VBR file can land at the physical end of
        // the audio data and fire AVPlayerItemDidPlayToEndTime before the seek
        // completion callback clears isSeeking. Ignore the notification in that case.
        guard !isSeeking else { return }
        // Cover the inverse race: the seek completion callback can clear isSeeking
        // before this notification is processed. Suppress only when both:
        //   1. A seek finished very recently (< 1s — rules out natural playback to end)
        //   2. The player landed close to where we intended (< 1s miss — rules out
        //      files whose audio is genuinely shorter than their duration metadata)
        // A short VBR file with a bad Xing header will have seekMiss >> 1s because
        // the player snaps to the physical end of audio rather than the intent.
        if let seekTime = lastSeekCompletedAt,
           Date().timeIntervalSince(seekTime) < 1.0,
           let playerTime = player?.currentItem?.currentTime().seconds,
           playerTime.isFinite, duration > 0 {
            let remaining = duration - playerTime
            let seekMiss = abs(playerTime - currentTime)
            if remaining > 3 && seekMiss < 1.0 {
                logPlayback("track_end_suppressed", "remaining=\(remaining) seek_miss=\(seekMiss)")
                return
            }
        }
        // If audio ended before the reported duration (e.g. bad VBR header from a
        // Plex MP3 transcode), snap the timeline to the actual end so the UI doesn't
        // briefly show false remaining time before advancing to the next track.
        if let playerTime = player?.currentItem?.currentTime().seconds,
           playerTime.isFinite, playerTime > 0, duration - playerTime > 1 {
            logPlayback("track_end_duration_correction", "reported=\(duration) actual=\(playerTime)")
            duration = playerTime
            currentTime = playerTime
        }
        let hasNext = currentIndex < queue.count - 1 || repeatMode != .off || isInfiniteModeActive
        logPlayback("track_end", "has_next=\(hasNext)")
        reportTimelineState("stopped", continuing: hasNext)
        advanceAfterTrackEnd()
    }

    /// Moves app state onto the enqueued item AVQueuePlayer has (or is about to)
    /// advance to, without rebuilding the player — this is what makes it gapless.
    func advanceToPreloadedTrack(_ preloaded: PreloadedNextTrack) {
        guard let player, let target = nextAutoAdvanceTarget(),
              target.track.ratingKey == preloaded.ratingKey else {
            logPlayback("gapless_advance_mismatch", "preloaded=\(preloaded.ratingKey)")
            discardPreloadedNext()
            next()
            return
        }

        reportTimelineState("stopped", continuing: true)
        tearDownObservers()

        preloadedNext = nil
        player.actionAtItemEnd = .none
        consumeRepeatOnce()

        let track = target.track
        currentIndex = target.index
        currentTrack = track
        recoveryTrackRatingKey = track.ratingKey
        recoveryAttemptsForTrack = 0
        playbackGeneration += 1
        pendingInitialSeekTime = nil
        streamTimeOffset = 0
        pendingStreamOffsetCalibration = false
        duration = Double(track.duration ?? 0) / 1000.0
        currentTime = currentTrackStartTime
        detailedTrackForSoundCheck = preloaded.detailedTrack
        universalCandidateIndexForCurrentItem = 0

        switch preloaded.source {
        case .local(let codec):
            isPlayingLocalFile = true
            localFileCodec = codec
            isDirectStreamAttempt = false
            isConstrainedPlaybackPath = false
            currentSessionID = nil
            universalStreamURL = nil
            universalCandidatesForCurrentItem = []
        case .direct:
            isPlayingLocalFile = false
            localFileCodec = nil
            isDirectStreamAttempt = true
            isConstrainedPlaybackPath = false
            currentSessionID = nil
            universalStreamURL = nil
            universalCandidatesForCurrentItem = []
        case .hls(let candidates, let sessionID, let shouldConstrain):
            isPlayingLocalFile = false
            localFileCodec = nil
            isDirectStreamAttempt = false
            isConstrainedPlaybackPath = shouldConstrain
            currentSessionID = sessionID
            universalStreamURL = preloaded.streamURL
            universalCandidatesForCurrentItem = candidates
        }

        let item = preloaded.item
        isReadyToPlay = item.status == .readyToPlay
        if item.status == .failed {
            logPlayback("gapless_item_already_failed", "track=\(track.ratingKey)")
        }
        let itemDuration = item.duration.seconds
        if !isPlayingLocalFile, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        player.automaticallyWaitsToMinimizeStalling = !isPlayingLocalFile
        player.volume = soundCheckVolume(for: track)

        logPlayback("gapless_advance", "to=\(track.ratingKey) index=\(target.index)")
        beginTrackSession(item: item)

        // Fallback if the pre-seek of the queued item didn't take.
        let start = currentTrackStartTime
        if start > 0, item.currentTime().seconds < start - 0.5 {
            seek(to: start)
        }
    }
}
