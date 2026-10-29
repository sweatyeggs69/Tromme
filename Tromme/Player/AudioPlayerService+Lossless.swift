import AVFoundation

// FLAC, ALAC, Opus and Vorbis playback through the Core Audio engine (SFBAudioEngine),
// from a downloaded file or streamed with HTTP range requests.
extension AudioPlayerService {
    /// Opens the track off the main thread, then starts it. Calls `onFailure` if it can't be opened.
    func loadCoreAudioTrack(url: URL, resumeAt: TimeInterval?, onFailure: @escaping () -> Void) {
        let generation = playbackGeneration
        playbackLoadTask?.cancel()
        playbackLoadTask = Task { @MainActor in
            do {
                let lossless = try await LocalLosslessPlayer.open(url: url)
                guard !Task.isCancelled, self.playbackGeneration == generation else {
                    lossless.stop()
                    return
                }
                self.startLosslessPlayback(lossless, resumeAt: resumeAt)
            } catch {
                guard !Task.isCancelled, self.playbackGeneration == generation else { return }
                self.logPlayback("lossless_open_failed", "error=\(error.localizedDescription)")
                onFailure()
            }
        }
    }

    /// Replaces the AVQueuePlayer pipeline with the opened player for this track.
    private func startLosslessPlayback(_ lossless: LocalLosslessPlayer, resumeAt: TimeInterval?) {
        tearDownObservers()
        player?.pause()
        player?.removeAllItems()
        player = nil
        stopLosslessPlayback()

        let generation = playbackGeneration
        lossless.onFinish = { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.handleLosslessFinished()
        }
        lossless.volume = soundCheckVolume(for: currentTrack)
        losslessPlayer = lossless
        isReadyToPlay = true
        // The decoder's length is exact, unlike Plex's rounded metadata. MP3s keep the
        // metadata duration since some files have corrupt Xing/VBR headers.
        logPlayback("lossless_duration", "plex=\(duration) file=\(lossless.duration)")
        let isMP3 = (currentTrack.flatMap(sourceAudioCodec(for:)) ?? localFileCodec?.lowercased()) == "mp3"
        if !isMP3, lossless.duration > 0 { duration = lossless.duration }

        if let resumeAt, resumeAt > 0 {
            let upper = duration > 1 ? duration - 1 : resumeAt
            lossless.currentTime = min(resumeAt, upper)
        }
        currentTime = lossless.currentTime
        pendingInitialSeekTime = nil

        if playbackIntent {
            lossless.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        lossless.onAdvance = { [weak self, weak lossless] in
            guard let self, let lossless, self.losslessPlayer === lossless else { return }
            self.advanceToQueuedEngineTrack(lossless)
        }
        startLosslessTicker(generation: generation)
        beginLosslessSession()
    }

    /// Same session setup beginTrackSession does for AVPlayer items; skipping it
    /// left the saved track and queue position stale after a quit.
    private func beginLosslessSession() {
        updateNowPlayingInfo()
        prefetchGainMetadata()
        prefetchUpcomingArtwork()
        maybeRefillInfiniteQueueIfNeeded(trigger: "start_playback")
        syncDynamicQueueDownloads()
        reportTimelineState(isPlaying ? "playing" : "paused")
        savePlaybackState()
    }

    // MARK: - Gapless

    /// Queues the next track on the engine when the current one is nearly done.
    func maybeQueueNextEngineTrack(within lead: TimeInterval = 25) {
        guard let lossless = losslessPlayer, engineQueued == nil, engineQueueTask == nil else { return }
        guard duration > 0, duration - currentTime <= lead else { return }
        guard let target = nextAutoAdvanceTarget(), let url = engineURL(for: target.track) else { return }
        let generation = playbackGeneration
        engineQueueTask = Task { @MainActor [weak self] in
            defer { self?.engineQueueTask = nil }
            do {
                try await lossless.enqueueNext(url: url)
                guard let self, !Task.isCancelled, self.playbackGeneration == generation,
                      self.losslessPlayer === lossless else {
                    lossless.clearQueue()
                    return
                }
                self.engineQueued = target
                self.logPlayback("engine_queue_complete", "track=\(target.track.ratingKey)")
            } catch {
                self?.logPlayback("engine_queue_failed", "error=\(error.localizedDescription)")
            }
        }
    }

    func discardEngineQueue() {
        engineQueueTask?.cancel()
        engineQueueTask = nil
        engineQueued = nil
        losslessPlayer?.clearQueue()
    }

    /// The URL the engine reads for a track: its download, or the original over range
    /// requests. Nil when cellular playback must use the HLS transcode instead.
    private func engineURL(for track: PlexMetadata) -> URL? {
        if let local = AppContext.shared.downloadManager.localURL(for: track.ratingKey) { return local }
        guard let server, let client else { return nil }
        let constrainedPath: Bool = switch resolvedPlaybackPath(for: server) {
        case .cellular, .wan, .relay: !UserDefaults.standard.bool(forKey: Self.disableCellularTranscodingKey)
        case .lan: false
        }
        let exceeds = sourceBitrate(for: track).map { $0 > Self.cellularTranscodeBitrateKbps } ?? true
        guard !(constrainedPath && exceeds),
              let partKey = track.media?.first?.part?.first?.key else { return nil }
        return client.directStreamURL(server: server, partKey: partKey)
    }

    /// Moves app state onto the track the engine just started playing without a gap.
    private func advanceToQueuedEngineTrack(_ lossless: LocalLosslessPlayer) {
        guard let target = engineQueued else { return }
        engineQueued = nil
        reportTimelineState("stopped", continuing: true)
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
        detailedTrackForSoundCheck = nil
        currentSessionID = nil
        isConstrainedPlaybackPath = false
        let record = AppContext.shared.downloadManager.records[track.ratingKey]
        isPlayingLocalFile = record != nil
        localFileCodec = record?.codecLabel(source: track.media?.first)
        isDirectStreamAttempt = record == nil

        duration = Double(track.duration ?? 0) / 1000.0
        let isMP3 = (sourceAudioCodec(for: track) ?? localFileCodec?.lowercased()) == "mp3"
        if !isMP3, lossless.duration > 0 { duration = lossless.duration }
        currentTime = 0
        lossless.volume = soundCheckVolume(for: track)
        isReadyToPlay = true
        logPlayback("engine_gapless_advance", "to=\(track.ratingKey) index=\(target.index)")

        let generation = playbackGeneration
        lossless.onFinish = { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.handleLosslessFinished()
        }
        startLosslessTicker(generation: generation)
        beginLosslessSession()
    }

    func stopLosslessPlayback() {
        engineQueueTask?.cancel()
        engineQueueTask = nil
        engineQueued = nil
        losslessTickTask?.cancel()
        losslessTickTask = nil
        losslessPlayer?.stop()
        losslessPlayer = nil
    }

    private func startLosslessTicker(generation: Int) {
        losslessTickTask?.cancel()
        losslessTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.playbackGeneration == generation,
                      let lossless = self.losslessPlayer else { return }
                guard !self.isSeeking, lossless.isPlaying else { continue }
                let seconds = lossless.currentTime
                self.currentTime = self.duration > 0 ? min(seconds, self.duration) : seconds
                if let track = self.currentTrack,
                   let stop = AppContext.shared.trackMarkers.stop(for: track.ratingKey),
                   seconds >= stop {
                    self.handleLosslessFinished()
                    return
                }
                self.maybePingTimeline()
                self.maybePlanAutoMix()
                self.maybeQueueNextEngineTrack()
            }
        }
    }

    func handleLosslessFinished() {
        losslessTickTask?.cancel()
        losslessTickTask = nil
        let hasNext = currentIndex < queue.count - 1 || repeatMode != .off || isInfiniteModeActive
        logPlayback("track_end", "has_next=\(hasNext) lossless=true")
        reportTimelineState("stopped", continuing: hasNext)
        advanceAfterTrackEnd()
    }

    func seekLossless(to time: TimeInterval) {
        guard let lossless = losslessPlayer else { return }
        recoveryAttemptsForTrack = 0
        lossless.currentTime = time
        currentTime = lossless.currentTime
        lastSeekCompletedAt = Date()
        if playbackIntent, !lossless.isPlaying {
            lossless.play()
            isPlaying = true
        }
        updateNowPlayingInfo()
        reportTimelineState(isPlaying ? "playing" : "paused")
    }

    /// Play/pause for the lossless player. A finished track restarts from the beginning.
    func toggleLosslessPlayback(_ lossless: LocalLosslessPlayer) {
        if lossless.isPlaying {
            lossless.pause()
            isPlaying = false
            playbackIntent = false
            reportTimelineState("paused")
        } else {
            playbackIntent = true
            if lossless.currentTime >= lossless.duration - 0.5 {
                lossless.currentTime = 0
                currentTime = 0
            }
            lossless.play()
            isPlaying = true
            reportTimelineState("playing")
            if losslessTickTask == nil { startLosslessTicker(generation: playbackGeneration) }
        }
        updateNowPlayingInfo()
    }
}
