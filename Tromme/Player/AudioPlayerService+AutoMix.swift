import AVFoundation

// Auto Mix: overlaps the end of one track with the start of the next, with a
// loudness-aware fade and, when both tracks have a steady beat, matched tempo and beats.
extension AudioPlayerService {
    static let autoMixKey = "autoMixEnabled"

    private nonisolated static let analysisLeadTime: TimeInterval = 110
    private nonisolated static let tailWindow: TimeInterval = 30
    private nonisolated static let headWindow: TimeInterval = 25

    /// True while a mix is fading between two tracks.
    var isAutoMixing: Bool { autoMixTask != nil }

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
        // Tracks in order on the same album stay gapless, so there is nothing to analyse.
        if isContinuousAlbum {
            autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0, introStart: nil, tempo: nil)
            return
        }
        let incomingBaseStart = AppContext.shared.trackMarkers.start(for: incoming.ratingKey) ?? 0
        let outgoingSource = autoMixAnalysisSource(for: current)
        let incomingSource = autoMixAnalysisSource(for: incoming)
        let generation = playbackGeneration
        AutoMixSourceCache.prune(keeping: [current.ratingKey, incoming.ratingKey])

        autoMixPlanTask = Task { [weak self] in
            async let tail = Self.analyzeTail(source: outgoingSource, end: end)
            async let head = Self.analyzeHead(source: incomingSource, from: incomingBaseStart)
            async let outgoingVocals = LyricsService.vocalSpan(for: current)
            async let incomingVocals = LyricsService.vocalSpan(for: incoming)
            let (outgoing, incomingAnalysis) = await (tail, head)
            let (outgoingSpan, incomingSpan) = await (outgoingVocals, incomingVocals)
            guard !Task.isCancelled, let self, self.playbackGeneration == generation else { return }
            self.autoMixPlanTask = nil
            guard let plan = AutoMixPlanner.plan(
                outgoingKey: current.ratingKey,
                incomingKey: incoming.ratingKey,
                outgoingEnd: end,
                incomingBaseStart: incomingBaseStart,
                outgoing: outgoing,
                incoming: incomingAnalysis,
                outgoingVocalEnd: outgoingSpan?.end,
                incomingVocalStart: incomingSpan?.start,
                isContinuousAlbum: isContinuousAlbum
            ) else {
                self.logPlayback("automix_skipped", "reason=continuous_album")
                self.autoMixPlan = AutoMixPlan(outgoingKey: current.ratingKey, incomingKey: incoming.ratingKey, startTime: .infinity, overlap: 0, introStart: nil, tempo: nil)
                return
            }
            self.logPlayback("automix_planned", "start=\(plan.startTime) overlap=\(plan.overlap) beat=\(plan.isBeatMatched) fadeIn=\(plan.incomingFadesIn) vocals=\(outgoingSpan != nil)/\(incomingSpan != nil)")
            self.autoMixPlan = plan
            self.scheduleAutoMixTrigger(plan, generation: generation)
        }
    }

    /// End of the audible content for the track that is playing: its duration or stop marker.
    private func autoMixEnd(for track: PlexMetadata) -> TimeInterval {
        let stop = AppContext.shared.trackMarkers.stop(for: track.ratingKey)
        return min(duration, stop ?? duration)
    }

    /// Where a track's audio can be read from: the download, or a temporary copy of the
    /// original file off cellular (the HLS transcode itself can't be read this way).
    struct AnalysisSource: Sendable {
        let url: URL
        let isTemporary: Bool
        let key: String
        let fileExtension: String
    }

    private func autoMixAnalysisSource(for track: PlexMetadata) -> AnalysisSource? {
        if let local = AppContext.shared.downloadManager.localURL(for: track.ratingKey) {
            return AnalysisSource(url: local, isTemporary: false, key: track.ratingKey, fileExtension: local.pathExtension)
        }
        guard !isCellular, let server, let client,
              let partKey = track.media?.first?.part?.first?.key,
              let url = client.directStreamURL(server: server, partKey: partKey) else { return nil }
        let container = (track.media?.first?.container ?? "mp3").lowercased()
        return AnalysisSource(url: url, isTemporary: true, key: track.ratingKey, fileExtension: container)
    }

    private nonisolated static func readableURL(_ source: AnalysisSource?) async -> URL? {
        guard let source else { return nil }
        guard source.isTemporary else { return source.url }
        return await AutoMixSourceCache.localCopy(of: source.url, key: source.key, fileExtension: source.fileExtension)
    }

    private nonisolated static func analyzeTail(source: AnalysisSource?, end: TimeInterval) async -> AutoMixWindowAnalysis? {
        guard let url = await readableURL(source) else { return nil }
        let start = max(0, end - tailWindow)
        return await AutoMixAnalyzer.analyze(url: url, from: start, length: tailWindow + 2, edge: .end)
    }

    private nonisolated static func analyzeHead(source: AnalysisSource?, from start: TimeInterval) async -> AutoMixWindowAnalysis? {
        guard let url = await readableURL(source) else { return nil }
        return await AutoMixAnalyzer.analyze(url: url, from: start, length: headWindow, edge: .start)
    }

    private func scheduleAutoMixTrigger(_ plan: AutoMixPlan, generation: Int) {
        // A streamed song takes a moment to start, so begin loading it a little early.
        // Beat-matched mixes keep the exact planned moment.
        let isLocal = AppContext.shared.downloadManager.localURL(for: plan.incomingKey) != nil
        let lead: TimeInterval = plan.tempo == nil && !isLocal ? 1.5 : 0.02
        autoMixTriggerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.playbackGeneration == generation else { return }
                let wait = plan.startTime - self.bestKnownPlaybackSeconds
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
                introStart: original.introStart, tempo: nil,
                incomingFadesIn: original.incomingFadesIn, filter: original.filter, curve: original.curve
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
        mixOutgoingOffset = streamTimeOffset
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
        runAutoMixFade(plan, generation: playbackGeneration, outgoingEnd: plan.startTime + plan.overlap)
    }

    private func runAutoMixFade(_ original: AutoMixPlan, generation: Int, outgoingEnd: TimeInterval) {
        let beganAt = Date()
        autoMixTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var plan = original
            var startedAt = beganAt

            // Without beat matching, hold the outgoing song at full volume until the new one is
            // audible, so a slow start never leaves a gap. The overlap shrinks to what is left.
            if plan.tempo == nil {
                while !Task.isCancelled {
                    guard self.playbackGeneration == generation, self.playbackIntent else {
                        self.finishAutoMix()
                        return
                    }
                    if self.isIncomingPlaying
                        || Date().timeIntervalSince(beganAt) > 8
                        || self.outgoingRemaining(until: outgoingEnd) < 0.4 { break }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                startedAt = Date()
                let remaining = self.outgoingRemaining(until: outgoingEnd)
                if remaining < plan.overlap { plan = plan.withOverlap(max(1.2, remaining)) }
            }

            var aligned = plan.tempo == nil
            while !Task.isCancelled {
                guard self.playbackGeneration == generation, self.playbackIntent else {
                    self.finishAutoMix()
                    return
                }
                let elapsed = Date().timeIntervalSince(startedAt)
                let progress = min(1, elapsed / plan.overlap)

                let gains = plan.curve.gains(progress)
                self.mixOutgoingPlayer?.volume = self.mixOutgoingVolume * gains.outgoing
                self.mixOutgoingLossless?.volume = self.mixOutgoingVolume * gains.outgoing
                // A song that fades in by itself reaches full level early so it isn't faded twice.
                self.mixIncomingGain = plan.incomingFadesIn
                    ? AutoMixPlan.Curve.equalPower.gains(min(1, progress / 0.35)).incoming
                    : gains.incoming
                self.applyIncomingVolume()

                self.applyMixFilters(plan.filter, progress: Float(progress))

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
        mixTap(for: player)?.set(.off, cutoff: 1000)
        if let player, player.timeControlStatus == .playing, player.rate != 1 {
            player.rate = 1
        }
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
