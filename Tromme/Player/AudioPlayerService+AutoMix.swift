import AVFoundation

extension AudioPlayerService {
    static let autoMixKey = "autoMixEnabled"
    static let crossfadeEnabledKey = "crossfadeEnabled"
    static let crossfadeLengthKey = "crossfadeSeconds"

    private static let planningLeadTime: TimeInterval = 150

    var isAutoMixing: Bool { autoMixInProgress }

    var isAutoMixEnabled: Bool { UserDefaults.standard.bool(forKey: Self.autoMixKey) && PlusStore.cachedIsPlus }

    private var isCrossfadeEnabled: Bool { UserDefaults.standard.bool(forKey: Self.crossfadeEnabledKey) }

    private var isMixingEnabled: Bool { isAutoMixEnabled || isCrossfadeEnabled }

    private var isFullAutoMixEnabled: Bool { isAutoMixEnabled }

    // MARK: - Planning

    func maybePlanAutoMix() {
        prefetchAutoMixLyrics()
        guard isMixingEnabled, repeatMode == .off,
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
        let markers = AppContext.shared.trackMarkers
        let isTrimmed = [current.ratingKey, incoming.ratingKey].contains {
            markers.start(for: $0) != nil || markers.stop(for: $0) != nil
        }
        if isContinuousAlbum || isTrimmed {
            recordAutoMix(current, incoming, "skipped: \(isContinuousAlbum ? "album order" : "trim markers")")
            autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0)
            return
        }
        let incomingBaseStart = AppContext.shared.trackMarkers.start(for: incoming.ratingKey) ?? 0
        let generation = playbackGeneration
        let client = client, server = server
        let soundCheckOn = UserDefaults.standard.bool(forKey: Self.soundCheckKey)
        let isPlus = isAutoMixEnabled
        let storedLength = UserDefaults.standard.double(forKey: Self.crossfadeLengthKey)
        let crossfadeLength = storedLength > 0 ? min(storedLength, 10) : AutoMixPlanner.defaultCrossfadeLength

        autoMixPlanTask = Task { [weak self] in
            async let outgoingVocals = Self.vocalSpan(current, if: isPlus)
            async let incomingVocals = Self.vocalSpan(incoming, if: isPlus)
            async let loudness = Self.loudnessDifference(current, incoming, soundCheckOn: soundCheckOn, client: client, server: server)
            let (outgoingSpan, incomingSpan) = await (outgoingVocals, incomingVocals)
            let loudnessDifference = await loudness
            guard !Task.isCancelled, let self, self.playbackGeneration == generation else { return }
            self.autoMixPlanTask = nil
            guard self.isMixingEnabled else { return }
            func planPlainCrossfade(reason: String) {
                var plan = AutoMixPlanner.crossfade(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, outgoingEnd: end, length: crossfadeLength)
                plan.loudnessDifference = loudnessDifference
                self.logPlayback("automix_planned", "crossfade=true reason=\(reason) start=\(plan.startTime)")
                self.recordAutoMix(current, incoming, "planned: plain crossfade", [
                    "reason": reason, "start": Self.seconds(plan.startTime), "overlap": Self.seconds(plan.overlap)
                ])
                self.autoMixPlan = plan
                self.scheduleAutoMixTrigger(plan, generation: generation)
            }
            guard isPlus, let outgoingSpan else {
                if isPlus && !self.isCrossfadeEnabled {
                    self.recordAutoMix(current, incoming, "skipped: no lyrics")
                    self.autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0)
                } else {
                    planPlainCrossfade(reason: isPlus ? "no_lyrics" : "automix_off")
                }
                return
            }
            guard var plan = AutoMixPlanner.plan(
                outgoingKey: current.ratingKey,
                incomingKey: incoming.ratingKey,
                outgoingEnd: end,
                incomingBaseStart: incomingBaseStart,
                outgoingLyricsEnd: outgoingSpan.end,
                outgoingLyricsEndMarked: outgoingSpan.endIsMarked,
                incomingVocalStart: incomingSpan?.start
            ) else {
                self.logPlayback("automix_skipped", "reason=lyrics_too_close_to_edge")
                self.recordAutoMix(current, incoming, "skipped: lyrics too close to the edge", [
                    "outgoingLyricsEnd": Self.seconds(outgoingSpan.end),
                    "incomingVocalStart": incomingSpan.map { Self.seconds($0.start) } ?? "none",
                    "outgoingEnd": Self.seconds(end)
                ])
                if self.isCrossfadeEnabled {
                    planPlainCrossfade(reason: "lyrics_too_close_to_edge")
                } else {
                    self.autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0)
                }
                return
            }
            plan.loudnessDifference = loudnessDifference
            self.logPlayback("automix_planned", "late=\(plan.startTime + plan.overlap < self.bestKnownPlaybackSeconds) start=\(plan.startTime) overlap=\(plan.overlap) intro=\(plan.introStart ?? -1) filter=\(plan.filter) vocals=true/\(incomingSpan != nil)")
            self.recordAutoMix(current, incoming, "planned: lyric mix", [
                "start": Self.seconds(plan.startTime), "overlap": Self.seconds(plan.overlap),
                "incomingStart": plan.introStart.map(Self.seconds) ?? "top", "filter": "\(plan.filter)",
                "incomingFade": plan.incomingFade.map(Self.seconds) ?? "none",
                "outgoingLyricsEnd": Self.seconds(outgoingSpan.end),
                "incomingVocalStart": incomingSpan.map { Self.seconds($0.start) } ?? "none",
                "outgoingEnd": Self.seconds(end),
                "loudnessDifferenceDb": plan.loudnessDifference.map(Self.seconds) ?? "none"
            ])
            self.autoMixPlan = plan
            self.scheduleAutoMixTrigger(plan, generation: generation)
        }
    }

    // MARK: - Report records

    private static func seconds(_ value: TimeInterval) -> String {
        value.isFinite ? String(format: "%.1f", value) : "never"
    }

    private func recordAutoMix(_ outgoing: PlexMetadata, _ incoming: PlexMetadata, _ outcome: String, _ values: [String: String] = [:]) {
        #if DEBUG
        autoMixRecords.removeAll { $0.outgoing.ratingKey == outgoing.ratingKey && $0.incoming.ratingKey == incoming.ratingKey }
        autoMixRecords.append(AutoMixRecord(outgoing: outgoing, incoming: incoming, outcome: outcome, values: values))
        if autoMixRecords.count > 4 { autoMixRecords.removeFirst(autoMixRecords.count - 4) }
        #endif
    }

    private func noteAutoMix(incomingKey: String, _ outcome: String, _ values: [String: String] = [:]) {
        #if DEBUG
        guard let index = autoMixRecords.lastIndex(where: { $0.incoming.ratingKey == incomingKey }) else { return }
        autoMixRecords[index].outcome = outcome
        autoMixRecords[index].values.merge(values) { _, new in new }
        #endif
    }

    private func prefetchAutoMixLyrics() {
        guard isFullAutoMixEnabled, let next = nextAutoAdvanceTarget()?.track,
              autoMixLyricsPrefetchKey != next.ratingKey else { return }
        autoMixLyricsPrefetchKey = next.ratingKey
        Task(priority: .utility) { _ = await LyricsService.vocalSpan(for: next) }
    }

    private nonisolated static func vocalSpan(_ track: PlexMetadata, if enabled: Bool) async -> (start: TimeInterval, end: TimeInterval, endIsMarked: Bool)? {
        guard enabled else { return nil }
        return await LyricsService.vocalSpan(for: track)
    }

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

    private func autoMixEnd(for track: PlexMetadata) -> TimeInterval {
        let stop = AppContext.shared.trackMarkers.stop(for: track.ratingKey)
        return min(duration, stop ?? duration)
    }

    private func scheduleAutoMixTrigger(_ plan: AutoMixPlan, generation: Int) {
        let isLocal = AppContext.shared.downloadManager.localURL(for: plan.incomingKey) != nil
        let lead: TimeInterval = isLocal ? 0.02 : 1.5
        autoMixTriggerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.playbackGeneration == generation else { return }
                guard self.isMixingEnabled else {
                    self.abandonAutoMix()
                    return
                }
                let now = self.bestKnownPlaybackSeconds
                let wait = plan.startTime - now
                if wait <= 30 { self.maybePreloadNextTrack(within: .infinity) }
                if wait <= 12 { self.prepareMixIncoming(plan) }
                if self.isPlaying, !self.isSeeking, wait <= lead {
                    self.beginAutoMix(plan, lateBy: max(0, -wait))
                    return
                }
                if self.isPlaying, !self.isSeeking, wait > lead, wait <= AutoMixPlanner.fadeSearchWindow,
                   let earliest = plan.earliestStart, now >= earliest,
                   self.mixTap(for: self.player)?.tonality.isFading == true {
                    self.maybePreloadNextTrack(within: .infinity)
                    self.prepareMixIncoming(plan)
                    if isLocal || self.mixPrepared?.ratingKey == plan.incomingKey {
                        self.beginAutoMix(plan.startingNow(at: now), lateBy: 0)
                        return
                    }
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
            noteAutoMix(incomingKey: original.incomingKey, "skipped: queue changed before the mix")
            abandonAutoMix()
            return
        }
        guard lateness <= 1.5 else {
            logPlayback("automix_skipped", "reason=past_start late=\(lateness)")
            noteAutoMix(incomingKey: original.incomingKey, "skipped: seeked past the mix start", ["lateBy": Self.seconds(lateness)])
            abandonAutoMix()
            autoMixPlan = AutoMixPlan(outgoingKey: original.outgoingKey, incomingKey: original.incomingKey, startTime: .infinity, overlap: 0)
            return
        }
        var plan = original

        tearDownObservers()
        if let preloaded = preloadedNext, let outgoing = player, outgoing.currentItem !== preloaded.item {
            if outgoing.items().contains(preloaded.item) { outgoing.remove(preloaded.item) }
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
        noteAutoMix(incomingKey: target.track.ratingKey, plan.isPlainCrossfade ? "mixed: plain crossfade" : "mixed: lyric mix", [
            "lateBy": Self.seconds(lateness), "filterUsed": "\(plan.filter)", "overlapUsed": Self.seconds(plan.overlap)
        ])
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
                let progress = plan.progress(at: Date().timeIntervalSince(startedAt))

                let gains = plan.gains(progress)
                let loudness = plan.loudnessFactors(progress)
                self.mixOutgoingPlayer?.volume = self.mixOutgoingVolume * gains.outgoing * loudness.outgoing
                self.mixOutgoingLossless?.volume = self.mixOutgoingVolume * gains.outgoing * loudness.outgoing
                self.mixIncomingGain = gains.incoming * loudness.incoming
                self.applyIncomingVolume()

                self.applyMixFilters(plan.filter, outgoing: Float(progress.outgoing), incoming: Float(progress.incoming))

                if progress.outgoing >= 1 {
                    self.finishAutoMix()
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

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

    func attachMixFilter(to item: AVPlayerItem, url: URL) {
        guard isFullAutoMixEnabled, url.isFileURL || !url.path.contains("transcode") else { return }
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

    private static func filterStyle(for tonality: AutoMixFilterTap.Tonality) -> AutoMixPlan.FilterStyle {
        guard tonality.seconds > 20, tonality.songLow > 0, tonality.songHigh > 0 else { return .mellow }
        let lowKept = tonality.recentLow / tonality.songLow
        let highKept = tonality.recentHigh / tonality.songHigh
        return lowKept < 0.4 && lowKept < highKept ? .energetic : .mellow
    }

    private func mixTap(for player: AVPlayer?) -> AutoMixFilterTap? {
        player?.currentItem.flatMap { mixTaps.object(forKey: $0) }
    }

    private func applyMixFilters(_ style: AutoMixPlan.FilterStyle, outgoing outgoingProgress: Float, incoming incomingProgress: Float) {
        guard style != .none else { return }
        func sweep(_ from: Float, _ to: Float, _ progress: Float) -> Float { from * pow(to / from, progress) }
        let outgoing = mixTap(for: mixOutgoingPlayer)
        let incoming = mixTap(for: player)
        let incomingDone = incomingProgress >= 0.97
        switch style {
        case .none:
            break
        case .energetic:
            outgoing?.set(.highPass, cutoff: sweep(40, 900, outgoingProgress))
            incoming?.set(incomingDone ? .off : .lowPass, cutoff: sweep(500, 18_000, incomingProgress))
        case .mellow:
            outgoing?.set(.lowPass, cutoff: sweep(18_000, 500, outgoingProgress))
            incoming?.set(incomingDone ? .off : .highPass, cutoff: sweep(900, 30, incomingProgress))
        }
    }
}
