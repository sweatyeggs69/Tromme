import AVFoundation

// Auto Mix: overlaps the end of one track with the start of the next, timed from their
// synced lyrics so the outro and intro carry the mix.
extension AudioPlayerService {
    static let autoMixKey = "autoMixEnabled"

    private static let planningLeadTime: TimeInterval = 150

    /// True while a lyric-timed mix plays (not a plain crossfade), for the timeline effect.
    /// Set before the next song loads.
    var isAutoMixing: Bool { autoMixInProgress }

    var isAutoMixEnabled: Bool { PlusStore.cachedIsPlus && UserDefaults.standard.bool(forKey: Self.autoMixKey) }

    // MARK: - Planning

    /// Called from the playback tick; reads both songs' lyrics timing shortly before the
    /// end, then waits for the planned start.
    func maybePlanAutoMix() {
        prefetchAutoMixLyrics()
        guard isAutoMixEnabled, repeatMode == .off,
              autoMixTask == nil, autoMixPlanTask == nil, autoMixTriggerTask == nil,
              duration > 20, duration - currentTime <= Self.planningLeadTime,
              playbackIntent, isPlaying,
              let current = currentTrack, let target = nextAutoAdvanceTarget(),
              target.track.ratingKey != current.ratingKey,
              autoMixPlan?.outgoingKey != current.ratingKey else { return }

        let incoming = target.track
        let end = autoMixEnd(for: current)
        let isContinuousAlbum = current.parentRatingKey != nil
            && current.parentRatingKey == incoming.parentRatingKey
            && (current.index ?? -1) + 1 == incoming.index
        // Tracks in order on the same album, and songs with trim markers, are never mixed:
        // they keep a plain gapless change at exactly the point the user set.
        let markers = AppContext.shared.trackMarkers
        let isTrimmed = [current.ratingKey, incoming.ratingKey].contains {
            markers.start(for: $0) != nil || markers.stop(for: $0) != nil
        }
        if isContinuousAlbum || isTrimmed {
            autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0)
            return
        }
        let incomingBaseStart = AppContext.shared.trackMarkers.start(for: incoming.ratingKey) ?? 0
        let generation = playbackGeneration
        let client = client, server = server
        let soundCheckOn = UserDefaults.standard.bool(forKey: Self.soundCheckKey)

        autoMixPlanTask = Task { [weak self] in
            async let outgoingVocals = LyricsService.vocalSpan(for: current)
            async let incomingVocals = LyricsService.vocalSpan(for: incoming)
            async let outgoingRule = AutoMixGenreRules.crossfadeReason(current, client: client, server: server)
            async let incomingRule = AutoMixGenreRules.crossfadeReason(incoming, client: client, server: server)
            async let outgoingLive = AutoMixGenreRules.isLiveOrMixRelease(current, client: client, server: server)
            async let incomingLive = AutoMixGenreRules.isLiveOrMixRelease(incoming, client: client, server: server)
            async let loudness = Self.loudnessDifference(current, incoming, soundCheckOn: soundCheckOn, client: client, server: server)
            let (outgoingSpan, incomingSpan) = await (outgoingVocals, incomingVocals)
            let (outgoingReason, incomingReason) = await (outgoingRule, incomingRule)
            let (outgoingIsLive, incomingIsLive) = await (outgoingLive, incomingLive)
            let isLiveOrMix = outgoingIsLive || incomingIsLive
            let loudnessDifference = await loudness
            guard !Task.isCancelled, let self, self.playbackGeneration == generation else { return }
            self.autoMixPlanTask = nil
            guard self.isAutoMixEnabled else { return }
            if isLiveOrMix {
                self.logPlayback("automix_skipped", "reason=live_or_mix_album")
                self.autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0)
                return
            }
            // Songs matched by the genre rules (or with no tags) get a plain crossfade.
            if outgoingReason != nil || incomingReason != nil {
                var plan = AutoMixPlanner.crossfade(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, outgoingEnd: end)
                plan.loudnessDifference = loudnessDifference
                self.logPlayback("automix_planned", "crossfade=true reason=\(outgoingReason ?? "-")/\(incomingReason ?? "-") start=\(plan.startTime)")
                self.autoMixPlan = plan
                self.scheduleAutoMixTrigger(plan, generation: generation)
                return
            }
            guard var plan = AutoMixPlanner.plan(
                outgoingKey: current.ratingKey,
                incomingKey: incoming.ratingKey,
                outgoingEnd: end,
                incomingBaseStart: incomingBaseStart,
                outgoingVocalEnd: outgoingSpan?.end,
                outgoingLastLyricEnd: outgoingSpan?.lastLineEnd,
                incomingVocalStart: incomingSpan?.start
            ) else {
                self.logPlayback("automix_skipped", "reason=lyrics_too_close_to_edge")
                self.autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0)
                return
            }
            plan.loudnessDifference = loudnessDifference
            self.logPlayback("automix_planned", "late=\(plan.startTime + plan.overlap < self.bestKnownPlaybackSeconds) start=\(plan.startTime) overlap=\(plan.overlap) intro=\(plan.introStart ?? -1) filter=\(plan.filter) vocals=\(outgoingSpan != nil)/\(incomingSpan != nil)")
            self.autoMixPlan = plan
            self.scheduleAutoMixTrigger(plan, generation: generation)
        }
    }

    /// Loads the next song's lyrics as soon as it is up next, so the plan never waits on them.
    private func prefetchAutoMixLyrics() {
        guard isAutoMixEnabled, let next = nextAutoAdvanceTarget()?.track,
              autoMixLyricsPrefetchKey != next.ratingKey else { return }
        autoMixLyricsPrefetchKey = next.ratingKey
        Task(priority: .utility) { _ = await LyricsService.vocalSpan(for: next) }
    }

    /// Outgoing minus incoming track gain (dB), only when Sound Check is off (it already
    /// evens out levels when on). Nil when either song has no ReplayGain data.
    private nonisolated static func loudnessDifference(_ outgoing: PlexMetadata, _ incoming: PlexMetadata, soundCheckOn: Bool,
                                                       client: PlexAPIClient?, server: PlexServer?) async -> Double? {
        guard !soundCheckOn, let client, let server else { return nil }
        func gain(_ track: PlexMetadata) async -> Double? {
            let detailed = try? await client.cachedMetadata(server: server, ratingKey: track.ratingKey)
            let stream = (detailed ?? track).media?.first?.part?.first?.stream?.first { $0.streamType == 2 }
            return stream?.gain ?? stream?.albumGain
        }
        async let outgoingGain = gain(outgoing)
        async let incomingGain = gain(incoming)
        guard let o = await outgoingGain, let i = await incomingGain else { return nil }
        return o - i
    }

    /// End of the audible content for the track that is playing: its duration or stop marker.
    private func autoMixEnd(for track: PlexMetadata) -> TimeInterval {
        let stop = AppContext.shared.trackMarkers.stop(for: track.ratingKey)
        return min(duration, stop ?? duration)
    }

    private func scheduleAutoMixTrigger(_ plan: AutoMixPlan, generation: Int) {
        // A streamed song takes a moment to start, so begin loading it a little early.
        let isLocal = AppContext.shared.downloadManager.localURL(for: plan.incomingKey) != nil
        let lead: TimeInterval = isLocal ? 0.02 : 1.5
        autoMixTriggerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.playbackGeneration == generation else { return }
                // Turned off after the mix was planned: back to a normal gapless ending.
                guard self.isAutoMixEnabled else {
                    self.abandonAutoMix()
                    return
                }
                let wait = plan.startTime - self.bestKnownPlaybackSeconds
                // A mix planned well before the end (a shortened outro) needs the next song
                // loaded sooner than the usual gapless preload.
                if wait <= 30 { self.maybePreloadNextTrack(within: .infinity) }
                if wait <= 12 { self.prepareMixIncoming(plan) }
                if self.isPlaying, !self.isSeeking, wait <= lead {
                    self.beginAutoMix(plan, lateBy: max(0, -wait))
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

    /// Drops a planned mix and the next song prepared for it. The gapless preload was taken
    /// off the queue for the mix, so it is discarded and the next tick preloads it again.
    private func abandonAutoMix() {
        logPlayback("automix_abandoned")
        cancelAutoMixPlanning()
        if let prepared = mixPrepared {
            prepared.player.pause()
            prepared.player.removeAllItems()
            mixPrepared = nil
            discardPreloadedNext()
        }
    }

    // MARK: - Mixing

    private func beginAutoMix(_ original: AutoMixPlan, lateBy lateness: TimeInterval) {
        autoMixTriggerTask = nil
        guard repeatMode == .off, playbackIntent, let target = nextAutoAdvanceTarget(),
              target.track.ratingKey == original.incomingKey else {
            logPlayback("automix_skipped", "reason=queue_changed")
            abandonAutoMix()
            return
        }
        // Past the planned start, almost always because the user seeked into or past the mix:
        // they chose where to listen, so the song ends normally instead.
        guard lateness <= 1.5 else {
            logPlayback("automix_skipped", "reason=past_start late=\(lateness)")
            abandonAutoMix()
            autoMixPlan = AutoMixPlan(outgoingKey: original.outgoingKey, incomingKey: original.incomingKey, startTime: .infinity, overlap: 0)
            return
        }
        var plan = original

        // Hand the playing output over: the new track loads through the normal path while
        // these keep sounding until the fade completes.
        tearDownObservers()
        if let preloaded = preloadedNext, let outgoing = player, outgoing.currentItem !== preloaded.item {
            if outgoing.items().contains(preloaded.item) { outgoing.remove(preloaded.item) }
            // Its asset is already loaded, which saves the new song a round trip.
            if preloaded.ratingKey == target.track.ratingKey { mixReusableAsset = preloaded.item.asset }
        }
        player?.actionAtItemEnd = .none
        mixOutgoingPlayer = player
        mixOutgoingLossless = losslessPlayer
        mixOutgoingVolume = player?.volume ?? losslessPlayer?.volume ?? 1
        mixOutgoingOffset = streamTimeOffset
        player = nil
        losslessPlayer = nil
        losslessTickTask?.cancel()
        losslessTickTask = nil

        if plan.filter != .none, let tonality = mixTap(for: mixOutgoingPlayer)?.tonality {
            plan.filter = Self.filterStyle(for: tonality)
        }
        mixIncomingGain = 0
        currentIndex = target.index
        logPlayback("automix_begin", "to=\(target.track.ratingKey) overlap=\(plan.overlap) filter=\(plan.filter)")
        // A streamed transcode can't start part-way without a new session, which would lose
        // the prepared song, so it starts from the top; the mix still ends before its lyrics.
        var resume = plan.introStart
        if case .hls? = preloadedNext?.source { resume = nil }
        autoMixInProgress = !plan.isPlainCrossfade
        loadAndPlay(target.track, resumeAt: resume)
        mixReusableAsset = nil
        autoMixPlan = plan
        runAutoMixFade(plan, generation: playbackGeneration, outgoingEnd: plan.startTime + plan.overlap)
    }

    private func runAutoMixFade(_ original: AutoMixPlan, generation: Int, outgoingEnd: TimeInterval) {
        autoMixTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var plan = original
            var beganAt = Date()

            // Hold the outgoing song at full volume until the new one is audible, so a slow
            // start never leaves a gap. The overlap shrinks to what is left.
            while !Task.isCancelled {
                guard self.playbackGeneration == generation else {
                    self.finishAutoMix()
                    return
                }
                if !self.playbackIntent {
                    beganAt += await self.holdMixWhilePaused(generation: generation)
                    continue
                }
                if self.isIncomingPlaying
                    || Date().timeIntervalSince(beganAt) > 8
                    || self.outgoingRemaining(until: outgoingEnd) < 0.4 { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            var startedAt = Date()
            let remaining = self.outgoingRemaining(until: outgoingEnd)
            if remaining < plan.overlap { plan = plan.withOverlap(max(1.2, remaining)) }

            while !Task.isCancelled {
                guard self.playbackGeneration == generation else {
                    self.finishAutoMix()
                    return
                }
                if !self.playbackIntent {
                    startedAt += await self.holdMixWhilePaused(generation: generation)
                    continue
                }
                let progress = min(1, Date().timeIntervalSince(startedAt) / plan.overlap)

                let gains = AutoMixPlan.gains(progress)
                let loudness = plan.loudnessFactors(progress)
                self.mixOutgoingPlayer?.volume = self.mixOutgoingVolume * gains.outgoing * loudness.outgoing
                self.mixOutgoingLossless?.volume = self.mixOutgoingVolume * gains.outgoing * loudness.outgoing
                self.mixIncomingGain = gains.incoming * loudness.incoming
                self.applyIncomingVolume()

                self.applyMixFilters(plan.filter, progress: Float(progress))

                if progress >= 1 {
                    self.finishAutoMix()
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    /// Pausing during a mix pauses the outgoing song too and resumes it with the new one, so
    /// the blend picks up where it stopped. Returns how long the mix was paused.
    private func holdMixWhilePaused(generation: Int) async -> TimeInterval {
        let pausedAt = Date()
        mixOutgoingPlayer?.pause()
        mixOutgoingLossless?.pause()
        while !Task.isCancelled, playbackGeneration == generation, !playbackIntent {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !Task.isCancelled, playbackGeneration == generation {
            mixOutgoingPlayer?.play()
            mixOutgoingLossless?.play()
        }
        return Date().timeIntervalSince(pausedAt)
    }

    private var isIncomingPlaying: Bool {
        if let losslessPlayer { return losslessPlayer.isPlaying }
        guard let player else { return false }
        return player.timeControlStatus == .playing && pendingInitialSeekTime == nil && isReadyToPlay
    }

    /// Seconds of the outgoing song left before `end` (track time).
    private func outgoingRemaining(until end: TimeInterval) -> TimeInterval {
        let time: TimeInterval
        if let outgoing = mixOutgoingPlayer {
            let seconds = outgoing.currentTime().seconds
            guard seconds.isFinite else { return .infinity }
            time = mixOutgoingOffset + seconds
        } else if let lossless = mixOutgoingLossless {
            time = lossless.currentTime
        } else {
            return .infinity
        }
        return max(0, end - time)
    }

    func applyIncomingVolume() {
        let volume = soundCheckVolume(for: currentTrack)
        player?.volume = volume
        losslessPlayer?.volume = volume
    }

    /// Releases the faded-out track and returns the new one to normal volume.
    func finishAutoMix() {
        autoMixTask?.cancel()
        autoMixTask = nil
        autoMixInProgress = false
        mixOutgoingPlayer?.pause()
        mixOutgoingPlayer?.removeAllItems()
        mixOutgoingPlayer = nil
        mixOutgoingLossless?.stop()
        mixOutgoingLossless = nil
        mixIncomingGain = 1
        applyIncomingVolume()
        mixTap(for: player)?.set(.off, cutoff: 1000)
    }

    // MARK: - Preparing

    /// Loads the next song silently ahead of the mix, at its start point, on its own player.
    private func prepareMixIncoming(_ plan: AutoMixPlan) {
        guard mixPrepared?.ratingKey != plan.incomingKey,
              let preloaded = preloadedNext, preloaded.ratingKey == plan.incomingKey,
              let outgoing = player,
              let track = nextAutoAdvanceTarget()?.track, track.ratingKey == plan.incomingKey else { return }

        if outgoing.currentItem !== preloaded.item, outgoing.items().contains(preloaded.item) {
            outgoing.remove(preloaded.item)
        }
        outgoing.actionAtItemEnd = .none

        let item = makePlayerItem(url: preloaded.streamURL, trimmedTo: track, asset: preloaded.item.asset)
        if case .local = preloaded.source {} else {
            item.preferredForwardBufferDuration = preferredFullTrackBufferDuration(for: Double(track.duration ?? 0) / 1000)
        }
        if case .hls = preloaded.source {} else {
            let start = plan.introStart ?? AppContext.shared.trackMarkers.start(for: track.ratingKey)
            if let start, start > 0 {
                let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
                item.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance, completionHandler: nil)
            }
        }
        let prepared = AVQueuePlayer(playerItem: item)
        prepared.actionAtItemEnd = .none
        prepared.automaticallyWaitsToMinimizeStalling = false
        prepared.volume = 0
        mixPrepared = PreparedMixIncoming(ratingKey: plan.incomingKey, url: preloaded.streamURL, player: prepared, item: item)
        logPlayback("automix_prepared", "track=\(plan.incomingKey)")
    }

    // MARK: - Filters

    /// Routes a file or progressive stream through a filter tap. HLS items can't be tapped.
    func attachMixFilter(to item: AVPlayerItem, url: URL) {
        guard isAutoMixEnabled, url.isFileURL || !url.path.contains("transcode") else { return }
        let tap = AutoMixFilterTap()
        mixTaps.setObject(tap, forKey: item)
        Task { [weak item] in
            guard let item,
                  let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
                  let parameters = tap.parameters(for: track) else { return }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    /// An ending that has lost its low end (a telephone or radio sound) is thinned further
    /// with a high-pass; one that has lost its top, or anything else, darkens with a low-pass.
    private static func filterStyle(for tonality: AutoMixFilterTap.Tonality) -> AutoMixPlan.FilterStyle {
        guard tonality.seconds > 20, tonality.songLow > 0, tonality.songHigh > 0 else { return .mellow }
        let lowKept = tonality.recentLow / tonality.songLow
        let highKept = tonality.recentHigh / tonality.songHigh
        return lowKept < 0.4 && lowKept < highKept ? .energetic : .mellow
    }

    private func mixTap(for player: AVPlayer?) -> AutoMixFilterTap? {
        player?.currentItem.flatMap { mixTaps.object(forKey: $0) }
    }

    private func applyMixFilters(_ style: AutoMixPlan.FilterStyle, progress: Float) {
        guard style != .none else { return }
        func sweep(_ from: Float, _ to: Float) -> Float { from * pow(to / from, progress) }
        let outgoing = mixTap(for: mixOutgoingPlayer)
        let incoming = mixTap(for: player)
        let incomingDone = progress >= 0.97
        switch style {
        case .none:
            break
        case .energetic:
            outgoing?.set(.highPass, cutoff: sweep(40, 900))
            incoming?.set(incomingDone ? .off : .lowPass, cutoff: sweep(500, 18_000))
        case .mellow:
            outgoing?.set(.lowPass, cutoff: sweep(18_000, 500))
            incoming?.set(incomingDone ? .off : .highPass, cutoff: sweep(900, 30))
        }
    }
}
