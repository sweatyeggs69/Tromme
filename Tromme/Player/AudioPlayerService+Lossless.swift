import AVFoundation

// FLAC, ALAC, Opus and Vorbis playback through the Core Audio engine (SFBAudioEngine),
// from a downloaded file or streamed with HTTP range requests.
extension AudioPlayerService {
    /// Codec labels (uppercased) that play through the Core Audio engine instead of AVPlayer.
    static func isLosslessLabel(_ codec: String?) -> Bool {
        ["FLAC", "ALAC", "OPUS", "VORBIS"].contains(codec?.uppercased() ?? "")
    }

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
        // The file header holds the exact length, unlike Plex's rounded metadata.
        logPlayback("lossless_duration", "plex=\(duration) file=\(lossless.duration)")
        duration = lossless.duration

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
        startLosslessTicker(generation: generation)
        // Same session setup beginTrackSession does for AVPlayer items; skipping it
        // left the saved track and queue position stale after a quit.
        updateNowPlayingInfo()
        prefetchGainMetadata()
        prefetchUpcomingArtwork()
        maybeRefillInfiniteQueueIfNeeded(trigger: "start_playback")
        syncDynamicQueueDownloads()
        reportTimelineState(isPlaying ? "playing" : "paused")
        savePlaybackState()
    }

    func stopLosslessPlayback() {
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
