import AVFoundation
import MediaPlayer
import Network
import Observation

// Audio route, interruption, network and AVPlayer observers.
extension AudioPlayerService {
    func observeSoundCheckToggle() {
        soundCheckObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let soundCheckOn = UserDefaults.standard.bool(forKey: Self.soundCheckKey)
                if soundCheckOn, self.detailedTrackForSoundCheck == nil,
                   let client = self.client, let server = self.server,
                   let ratingKey = self.currentTrack?.ratingKey {
                    self.detailedTrackForSoundCheck = try? await client.cachedMetadata(
                        server: server, ratingKey: ratingKey
                    )
                }
                self.player?.volume = self.soundCheckVolume(for: self.currentTrack)
                self.losslessPlayer?.volume = self.soundCheckVolume(for: self.currentTrack)
            }
        }
    }

    func observeAudioRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let reason: AVAudioSession.RouteChangeReason? = {
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return nil }
                return AVAudioSession.RouteChangeReason(rawValue: raw)
            }()
            Task { @MainActor in
                self.refreshAirPlayConnectionState()
                if reason == .oldDeviceUnavailable, self.isPlaying {
                    self.logPlayback("route_old_device_unavailable_pausing")
                    self.pauseCurrent()
                }
            }
        }
    }

    func observeAudioInterruptions() {
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleAudioSessionDidBecomeInactive()
            }
        }
        audioResumptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let context = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            let recommendsResume = context?.recommendation == .shouldResume
            Task { @MainActor in
                await self.handleAudioResumptionRecommendation(recommendsResume: recommendsResume)
            }
        }
    }

    func handleAudioSessionDidBecomeInactive() {
        wasInterruptedWhilePlaying = isPlaying
        if isPlaying {
            isPlaying = false
            updateNowPlayingInfo()
        }
        logPlayback("audio_session_became_inactive", "was_playing=\(wasInterruptedWhilePlaying)")
    }

    func handleAudioResumptionRecommendation(recommendsResume: Bool) async {
        let shouldResume = recommendsResume && wasInterruptedWhilePlaying
        logPlayback("audio_resumption_recommendation", "should_resume=\(shouldResume)")
        wasInterruptedWhilePlaying = false
        guard shouldResume else { return }
        do {
            try await activateAudioSession()
        } catch {
            logPlayback("audio_session_reactivate_failed", "error=\(error.localizedDescription)")
            return
        }
        if let losslessPlayer {
            losslessPlayer.play()
            isPlaying = true
            updateNowPlayingInfo()
            reportTimelineState("playing")
        } else if let player, let item = player.currentItem, item.status != .failed {
            player.play()
            isPlaying = true
            updateNowPlayingInfo()
            reportTimelineState("playing")
        } else {
            recoverAndPlayCurrentTrackIfPossible(resumeAt: preferredResumeTimeForRecovery())
        }
    }

    func observeNetworkChanges() {
        lastNetworkInterfaceType = NetworkStatus.shared.interfaceType
        lastNetworkIsConnected = NetworkStatus.shared.isConnected
        networkChangeObserver = NotificationCenter.default.addObserver(
            forName: NetworkStatus.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleNetworkPathChange()
            }
        }
    }

    func handleNetworkPathChange() {
        let newType = NetworkStatus.shared.interfaceType
        let newConnected = NetworkStatus.shared.isConnected
        let oldType = lastNetworkInterfaceType
        let oldConnected = lastNetworkIsConnected
        lastNetworkInterfaceType = newType
        lastNetworkIsConnected = newConnected
        // Adds or removes lock screen animated artwork when Low Data Mode flips.
        updateNowPlayingInfo()

        let interfaceChanged = newType != oldType
        let lostConnection = oldConnected && !newConnected
        let reconnected = !oldConnected && newConnected
        guard interfaceChanged || reconnected || lostConnection else { return }
        if newConnected, let server, let client {
            Task { await TimelineOutbox.shared.flush(server: server, client: client) }
        }
        revalidatePreloadedNext(networkChanged: true)
        guard isPlaying, currentTrack != nil else { return }

        logPlayback("network_path_change", "interface_changed=\(interfaceChanged) lost=\(lostConnection) reconnected=\(reconnected)")

        isNetworkRecovering = true
        networkRecoveryTask?.cancel()
        let generation = playbackGeneration
        networkRecoveryTask = Task {
            defer {
                Task { @MainActor in
                    self.isNetworkRecovering = false
                }
            }

            let connectivityDeadline = Date().addingTimeInterval(30)
            while !NetworkStatus.shared.isConnected && Date() < connectivityDeadline {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                if self.playbackGeneration != generation { return }
                if !self.isPlaying { return }
            }
            guard NetworkStatus.shared.isConnected else {
                self.logPlayback("network_recovery_no_connectivity")
                return
            }

            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self.playbackGeneration == generation, self.isPlaying else { return }

            await AppContext.shared.serverConnection.reprobe()
            guard !Task.isCancelled, self.playbackGeneration == generation, self.isPlaying else { return }

            if let updatedServer = AppContext.shared.serverConnection.currentServer {
                self.server = updatedServer
            }

            if self.isCurrentItemFullyBuffered {
                self.logPlayback("network_recovery_skipped", "reason=fully_buffered")
                return
            }

            self.recoveryAttemptsForTrack = 0
            self.recoverAndPlayCurrentTrackIfPossible(resumeAt: self.preferredResumeTimeForRecovery())
            self.logPlayback("network_recovery_rebuild")
        }
    }

    // MARK: - Observers

    /// Watches the player item's status. Once .readyToPlay fires, loads the
    /// authoritative duration from the parsed STREAMINFO / container header.
    func observeItemStatus(_ item: AVPlayerItem) {
        // .initial so an item that is already ready (a prepared Auto Mix song) is handled too.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let assetDuration = observedItem.duration.seconds
            let errorDesc = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isReadyToPlay = true
                    let durationBeforeReady = self.duration
                    // An offset stream's asset duration only covers the remainder
                    // of the track, so keep the metadata duration in that case.
                    // Local files keep Plex metadata duration — downloaded MP3
                    // transcodes can have corrupt Xing/VBR headers. Lossless files
                    // (FLAC/ALAC) carry an exact sample count, so their asset
                    // duration is authoritative and keeps the timeline in sync.
                    let trustsAssetDuration = !self.isPlayingLocalFile
                        || ["FLAC", "ALAC"].contains(self.localFileCodec ?? "")
                    if trustsAssetDuration, self.streamTimeOffset == 0,
                       assetDuration.isFinite && assetDuration > 0 {
                        if self.isPlayingLocalFile {
                            self.logPlayback("local_duration", "plex=\(self.duration) asset=\(assetDuration)")
                        }
                        self.duration = assetDuration
                    }
                    self.logPlayback("item_ready", "duration=\(self.duration) offset=\(self.streamTimeOffset)")

                    if let pendingSeek = self.pendingInitialSeekTime {
                        self.pendingInitialSeekTime = nil
                        let safeUpper = self.duration > 1 ? max(self.duration - 1, 0) : self.duration
                        let bounded = safeUpper > 0 ? min(max(0, pendingSeek), safeUpper) : max(0, pendingSeek)
                        let seekGeneration = self.playbackGeneration
                        self.logPlayback("resume_seek", "to=\(bounded)")
                        self.isSeeking = true
                        let target = CMTime(seconds: bounded, preferredTimescale: 600)
                        // Local files: 50ms tolerance — imperceptible but avoids
                        // finished=false on VBR files that have no sample at the exact time.
                        // HLS streams need more slack for playlist segment boundaries.
                        let tolerance = self.isPlayingLocalLossless ? CMTime.zero
                            : self.isPlayingLocalFile ? CMTime(seconds: 0.05, preferredTimescale: 600)
                            : CMTime(seconds: 0.25, preferredTimescale: 600)
                        self.player?.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                            guard let self else { return }
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.isSeeking = false
                                self.lastSeekCompletedAt = Date()
                                guard self.playbackGeneration == seekGeneration, finished else { return }
                                self.currentTime = bounded
                                if self.playbackIntent {
                                    self.isPlaying = true
                                    self.player?.play()
                                } else {
                                    self.isPlaying = false
                                }
                                self.updateNowPlayingInfo()
                                self.reportTimelineState(self.isPlaying ? "playing" : "paused")
                            }
                        }
                        // The seek completion above republishes nowPlayingInfo
                        // once it lands, so skip the immediate call below —
                        // otherwise CarPlay's transport row gets two rewrites
                        // (rate/duration unchanged in between) in the same beat,
                        // which visibly flashes the play/pause button.
                    } else if abs(self.duration - durationBeforeReady) > 0.5 {
                        // Only republish if the asset's authoritative duration
                        // actually corrected the metadata-derived estimate from
                        // startPlayback() by more than floating-point/rounding
                        // noise. Plex's metadata duration and AVFoundation's
                        // parsed asset duration are almost never bit-for-bit
                        // equal even when they agree to the second, so a strict
                        // != comparison republished nowPlayingInfo on nearly
                        // every track start — a no-op rewrite (rate/duration
                        // unchanged in any way a user would notice) that still
                        // causes CarPlay to flash the play/pause button.
                        self.updateNowPlayingInfo()
                    }
                case .failed:
                    self.isReadyToPlay = false
                    self.logPlayback("item_failed", "error=\(errorDesc ?? "unknown")")
                    if self.isNetworkRecovering {
                        self.logPlayback("item_failed_deferred_network_recovery")
                        return
                    }
                    let nextIndex = self.universalCandidateIndexForCurrentItem + 1
                    if self.universalCandidatesForCurrentItem.indices.contains(nextIndex) {
                        self.universalCandidateIndexForCurrentItem = nextIndex
                        let nextURL = self.universalCandidatesForCurrentItem[nextIndex]
                        self.universalStreamURL = nextURL
                        self.startPlayback(url: nextURL)
                        return
                    }
                    self.handlePlaybackFailure("item_failed")
                default:
                    break
                }
            }
        }
    }

    func observePlaybackFailures(_ item: AVPlayerItem) {
        let observedGeneration = playbackGeneration

        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.playbackGeneration == observedGeneration else { return }

                if self.isNetworkRecovering {
                    self.logPlayback("stall_deferred_network_recovery")
                    return
                }

                guard self.playbackIntent else {
                    self.logPlayback("stall_ignored", "reason=paused")
                    return
                }

                self.logPlayback("playback_stalled")
                self.player?.play()

                let stallStartTime = self.bestKnownPlaybackSeconds

                try? await Task.sleep(for: .seconds(6))
                guard self.playbackGeneration == observedGeneration else { return }
                guard self.currentTrack?.ratingKey == self.recoveryTrackRatingKey else { return }
                if self.isNetworkRecovering {
                    self.logPlayback("stall_deferred_network_recovery")
                    return
                }

                let status = self.player?.timeControlStatus
                let waitingReason = self.player?.reasonForWaitingToPlay
                let progressed = self.bestKnownPlaybackSeconds - stallStartTime

                self.logPlayback("stall_check", "status=\(status?.rawValue ?? -1) waiting_reason=\(waitingReason?.rawValue ?? "none") progressed=\(progressed)")

                if status == .playing || progressed > 1 {
                    return
                }

                if status == .waitingToPlayAtSpecifiedRate, waitingReason == .toMinimizeStalls {
                    self.logPlayback("stall_grace", "reason=toMinimizeStalls")
                    try? await Task.sleep(for: .seconds(10))
                    guard self.playbackGeneration == observedGeneration else { return }
                    guard self.currentTrack?.ratingKey == self.recoveryTrackRatingKey else { return }
                    if self.isNetworkRecovering {
                        self.logPlayback("stall_deferred_network_recovery")
                        return
                    }

                    let recheckStatus = self.player?.timeControlStatus
                    let recheckProgressed = self.bestKnownPlaybackSeconds - stallStartTime
                    self.logPlayback("stall_recheck", "status=\(recheckStatus?.rawValue ?? -1) progressed=\(recheckProgressed)")

                    if recheckStatus == .playing || recheckProgressed > 1 {
                        return
                    }
                }

                self.handlePlaybackFailure("playback_stalled")
            }
        }

        itemFailedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.playbackGeneration == observedGeneration else { return }
                if self.isNetworkRecovering {
                    self.logPlayback("item_failed_deferred_network_recovery")
                    return
                }
                self.logPlayback("failed_to_play_to_end")
                self.handlePlaybackFailure("failed_to_end")
            }
        }
    }

    func tearDownObservers() {
        removeTimeObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        if let trackEndObserver {
            NotificationCenter.default.removeObserver(trackEndObserver)
        }
        trackEndObserver = nil
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = nil
        if let itemFailedToEndObserver {
            NotificationCenter.default.removeObserver(itemFailedToEndObserver)
        }
        itemFailedToEndObserver = nil
        isSeeking = false
    }
}
