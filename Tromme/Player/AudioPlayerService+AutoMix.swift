import AVFoundation

// Auto Mix: overlaps the end of one track with the start of the next, with a
// loudness-aware fade and, when both tracks have a steady beat, matched tempo and beats.
extension AudioPlayerService {
    static let autoMixKey = "autoMixEnabled"

    private nonisolated static let analysisLeadTime: TimeInterval = 75
    private nonisolated static let tailWindow: TimeInterval = 30
    private nonisolated static let headWindow: TimeInterval = 25

    var isAutoMixEnabled: Bool { PlusStore.cachedIsPlus && UserDefaults.standard.bool(forKey: Self.autoMixKey) }

    // MARK: - Planning

    /// Called from the playback tick; analyses the current and next tracks shortly
    /// before the end, then waits for the planned start.
    func maybePlanAutoMix() {
        guard isAutoMixEnabled, repeatMode == .off,
              autoMixTask == nil, autoMixPlanTask == nil, autoMixTriggerTask == nil,
              duration > 20, duration - currentTime <= Self.analysisLeadTime,
              playbackIntent, isPlaying,
              let current = currentTrack, let target = nextAutoAdvanceTarget(),
              target.track.ratingKey != current.ratingKey,
              autoMixPlan?.outgoingKey != current.ratingKey else { return }

        let incoming = target.track
        let end = autoMixEnd(for: current)
        let isContinuousAlbum = current.parentRatingKey != nil
            && current.parentRatingKey == incoming.parentRatingKey
            && (current.index ?? -1) + 1 == incoming.index
        let incomingBaseStart = AppContext.shared.trackMarkers.start(for: incoming.ratingKey) ?? 0
        let outgoingURL = autoMixAnalysisURL(for: current)
        let incomingURL = autoMixAnalysisURL(for: incoming)
        let generation = playbackGeneration

        autoMixPlanTask = Task { [weak self] in
            async let tail = Self.analyzeTail(url: outgoingURL, end: end)
            async let head = Self.analyzeHead(url: incomingURL, from: incomingBaseStart)
            let (outgoing, incomingAnalysis) = await (tail, head)
            guard !Task.isCancelled, let self, self.playbackGeneration == generation else { return }
            self.autoMixPlanTask = nil
            guard let plan = AutoMixPlanner.plan(
                outgoingKey: current.ratingKey,
                incomingKey: incoming.ratingKey,
                outgoingEnd: end,
                incomingBaseStart: incomingBaseStart,
                outgoing: outgoing,
                incoming: incomingAnalysis,
                isContinuousAlbum: isContinuousAlbum
            ) else {
                self.logPlayback("automix_skipped", "reason=continuous_album")
                self.autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0, introStart: nil, tempo: nil)
                return
            }
            self.logPlayback("automix_planned", "start=\(plan.startTime) overlap=\(plan.overlap) beat=\(plan.isBeatMatched)")
            self.autoMixPlan = plan
            self.scheduleAutoMixTrigger(plan, generation: generation)
        }
    }

    /// End of the audible content for the track that is playing: its duration or stop marker.
    private func autoMixEnd(for track: PlexMetadata) -> TimeInterval {
        let stop = AppContext.shared.trackMarkers.stop(for: track.ratingKey)
        return min(duration, stop ?? duration)
    }

    /// A file AVAssetReader can decode: the download, or the direct stream for non-FLAC
    /// sources off cellular. Transcoded HLS sessions can't be read this way.
    private func autoMixAnalysisURL(for track: PlexMetadata) -> URL? {
        if let local = AppContext.shared.downloadManager.localURL(for: track.ratingKey) { return local }
        guard !isCellular, sourceAudioCodec(for: track) != "flac",
              let server, let client,
              let partKey = track.media?.first?.part?.first?.key else { return nil }
        return client.directStreamURL(server: server, partKey: partKey)
    }

    private nonisolated static func analyzeTail(url: URL?, end: TimeInterval) async -> AutoMixWindowAnalysis? {
        guard let url else { return nil }
        let start = max(0, end - tailWindow)
        return await AutoMixAnalyzer.analyze(url: url, from: start, length: tailWindow + 2)
    }

    private nonisolated static func analyzeHead(url: URL?, from start: TimeInterval) async -> AutoMixWindowAnalysis? {
        guard let url else { return nil }
        return await AutoMixAnalyzer.analyze(url: url, from: start, length: headWindow)
    }

    private func scheduleAutoMixTrigger(_ plan: AutoMixPlan, generation: Int) {
        autoMixTriggerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.playbackGeneration == generation else { return }
                let wait = plan.startTime - self.bestKnownPlaybackSeconds
                if self.isPlaying, !self.isSeeking, wait <= 0.02 {
                    self.beginAutoMix(plan, lateBy: -wait)
                    return
                }
                let nap = self.isPlaying ? min(max(wait, 0.02), 0.25) : 0.25
                try? await Task.sleep(for: .milliseconds(Int(nap * 1000)))
            }
        }
    }

    func cancelAutoMixPlanning() {
        autoMixPlanTask?.cancel()
        autoMixPlanTask = nil
        autoMixTriggerTask?.cancel()
        autoMixTriggerTask = nil
        autoMixPlan = nil
    }

    // MARK: - Mixing

    private func beginAutoMix(_ original: AutoMixPlan, lateBy lateness: TimeInterval) {
        autoMixTriggerTask = nil
        guard repeatMode == .off, playbackIntent, let target = nextAutoAdvanceTarget(),
              target.track.ratingKey == original.incomingKey else { return }

        // Past the planned start (a seek, or analysis that finished late): mix from now,
        // and drop the beat match because its phase no longer lines up.
        var plan = original
        if lateness > 1.5 {
            let remaining = original.startTime + original.overlap - bestKnownPlaybackSeconds
            guard remaining > 1.5 else { return }
            plan = AutoMixPlan(
                outgoingKey: original.outgoingKey, incomingKey: original.incomingKey,
                startTime: bestKnownPlaybackSeconds, overlap: min(original.overlap, remaining),
                introStart: original.introStart, tempo: nil
            )
        }

        // Hand the playing output over: the new track loads through the normal path while
        // these keep sounding until the fade completes.
        tearDownObservers()
        if let preloaded = preloadedNext, let outgoing = player, outgoing.currentItem !== preloaded.item {
            outgoing.remove(preloaded.item)
        }
        player?.actionAtItemEnd = .none
        player?.currentItem?.audioTimePitchAlgorithm = .spectral
        mixOutgoingPlayer = player
        mixOutgoingLossless = losslessPlayer
        mixOutgoingVolume = player?.volume ?? losslessPlayer?.volume ?? 1
        player = nil
        losslessPlayer = nil
        losslessTickTask?.cancel()
        losslessTickTask = nil

        mixIncomingGain = 0
        currentIndex = target.index
        logPlayback("automix_begin", "to=\(target.track.ratingKey) overlap=\(plan.overlap) beat=\(plan.isBeatMatched)")
        loadAndPlay(target.track, resumeAt: plan.introStart)
        autoMixPlan = plan
        autoMixTransition = AutoMixTransition(duration: plan.overlap, isBeatMatched: plan.isBeatMatched)
        runAutoMixFade(plan, generation: playbackGeneration)
    }

    private func runAutoMixFade(_ plan: AutoMixPlan, generation: Int) {
        let startedAt = Date()
        autoMixTask = Task { @MainActor [weak self] in
            var aligned = plan.tempo == nil
            while !Task.isCancelled {
                guard let self else { return }
                guard self.playbackGeneration == generation, self.playbackIntent else {
                    self.finishAutoMix()
                    return
                }
                let elapsed = Date().timeIntervalSince(startedAt)
                let progress = min(1, elapsed / plan.overlap)

                // Equal-power curves keep the combined loudness steady through the overlap.
                self.mixOutgoingPlayer?.volume = self.mixOutgoingVolume * Float(cos(progress * .pi / 2))
                self.mixOutgoingLossless?.volume = self.mixOutgoingVolume * Float(cos(progress * .pi / 2))
                self.mixIncomingGain = Float(sin(progress * .pi / 2))
                self.applyIncomingVolume()

                if let tempo = plan.tempo {
                    let shared = tempo.blended(at: progress)
                    if let outgoing = self.mixOutgoingPlayer, outgoing.timeControlStatus == .playing {
                        Self.setRate(outgoing, Float(shared / tempo.outgoing))
                    }
                    if let incoming = self.player, self.pendingInitialSeekTime == nil,
                       incoming.timeControlStatus == .playing {
                        Self.setRate(incoming, Float(shared / tempo.incoming))
                        if !aligned {
                            aligned = true
                            self.alignIncoming(incoming, plan: plan, elapsed: elapsed)
                        }
                    }
                }

                if progress >= 1 {
                    self.finishAutoMix()
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    /// A streamed track starts a little after the planned moment; jump it forward by the
    /// delay so its beats still land on the outgoing track's.
    private func alignIncoming(_ incoming: AVQueuePlayer, plan: AutoMixPlan, elapsed: TimeInterval) {
        let expected = (plan.introStart ?? currentTrackStartTime) + plan.incomingMediaElapsed(elapsed)
        let actual = incoming.currentTime().seconds
        guard actual.isFinite, expected - actual > 0.05, expected - actual < 3 else { return }
        logPlayback("automix_align", "skip=\(expected - actual)")
        let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
        incoming.seek(to: CMTime(seconds: expected, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance, completionHandler: { _ in })
    }

    private static func setRate(_ player: AVPlayer, _ rate: Float) {
        guard abs(player.rate - rate) > 0.002 else { return }
        player.rate = rate
    }

    func applyIncomingVolume() {
        let volume = soundCheckVolume(for: currentTrack)
        player?.volume = volume
        losslessPlayer?.volume = volume
    }

    /// Releases the faded-out track and returns the new one to normal volume and speed.
    func finishAutoMix() {
        autoMixTask?.cancel()
        autoMixTask = nil
        mixOutgoingPlayer?.pause()
        mixOutgoingPlayer?.removeAllItems()
        mixOutgoingPlayer = nil
        mixOutgoingLossless?.stop()
        mixOutgoingLossless = nil
        mixIncomingGain = 1
        applyIncomingVolume()
        if let player, player.timeControlStatus == .playing, player.rate != 1 {
            player.rate = 1
        }
    }
}
