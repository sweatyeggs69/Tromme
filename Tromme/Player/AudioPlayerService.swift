import AVFoundation
import MediaPlayer
import Network
import Observation

@Observable @MainActor
final class AudioPlayerService: Sendable {
    var currentTrack: PlexMetadata?
    var queue: [PlexMetadata] = [] {
        didSet {
            maybeRefillInfiniteQueueIfNeeded(trigger: "queue_changed")
            revalidatePreloadedNext()
        }
    }
    var currentIndex: Int = 0 {
        didSet {
            maybeRefillInfiniteQueueIfNeeded(trigger: "index_changed")
            trimPlayedHistoryIfNeeded()
        }
    }
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShuffled = false
    var repeatMode: RepeatMode = .off {
        didSet { revalidatePreloadedNext() }
    }
    var isMagicMixActive: Bool { magicMixBuildTask != nil }
    var isInfiniteModeActive = false {
        didSet {
            UserDefaults.standard.set(isInfiniteModeActive, forKey: Self.infiniteModeKey)
            maybeRefillInfiniteQueueIfNeeded(trigger: "infinite_mode_toggled")
        }
    }
    var isReadyToPlay = false
    var isAirPlayConnected = false
    var isCarPlayConnected = false
    var activeRouteName: String?

    enum RepeatMode: String, Sendable {
        case off, song, once

        var iconName: String {
            switch self {
            case .off, .song: "repeat"
            case .once: "repeat.1"
            }
        }

        var isActive: Bool { self != .off }
    }

    var player: AVQueuePlayer?
    var losslessPlayer: LocalLosslessPlayer?
    var losslessTickTask: Task<Void, Never>?
    var timeObserver: Any?
    var statusObservation: NSKeyValueObservation?
    var timeControlObservation: NSKeyValueObservation?
    var currentItemObservation: NSKeyValueObservation?
    var trackEndObserver: Any?
    var playbackStalledObserver: Any?
    var itemFailedToEndObserver: Any?
    var playbackGeneration: Int = 0
    var playbackIntent: Bool = false
    var lastPublishedNowPlayingTrackKey: String?
    var lastPublishedNowPlayingDate = Date.distantPast
    let maxRecoveryAttemptsPerTrack = 2
    var recoveryTrackRatingKey: String?
    var recoveryAttemptsForTrack = 0
    var server: PlexServer?
    var client: PlexAPIClient?
    var originalQueue: [PlexMetadata] = []
    var universalStreamURL: URL?
    var universalCandidatesForCurrentItem: [URL] = []
    var universalCandidateIndexForCurrentItem = 0
    var currentSessionID: String?
    var detailedTrackForSoundCheck: PlexMetadata?
    var cachedArtwork: MPMediaItemArtwork?
    var cachedArtworkThumbPath: String?
    var isConstrainedPlaybackPath = false
    var isCellular: Bool { NetworkStatus.shared.isCellular }
    var isSeeking = false
    var soundCheckObserver: NSObjectProtocol?
    var routeChangeObserver: NSObjectProtocol?
    var audioInterruptionObserver: NSObjectProtocol?
    var audioResumptionObserver: NSObjectProtocol?
    var wasInterruptedWhilePlaying = false
    var networkChangeObserver: NSObjectProtocol?
    var networkRecoveryTask: Task<Void, Never>?
    var lastNetworkInterfaceType: NWInterface.InterfaceType?
    var lastNetworkIsConnected: Bool = true
    var isNetworkRecovering: Bool = false
    #if DEBUG
    var lastLoggedTimeControlStatus: AVPlayer.TimeControlStatus?
    #endif
    var isPlayingLocalFile = false
    var localFileCodec: String?
    var isDirectStreamAttempt = false
    var pendingInitialSeekTime: TimeInterval?
    var streamTimeOffset: TimeInterval = 0
    var pendingStreamOffsetCalibration = false
    var heldSeekTask: Task<Void, Never>?
    var heldSeekTargetTime: TimeInterval = 0
    var lastSavedQueueHash: Int?
    var lastSavedOriginalQueueHash: Int?
    var lastTimelineReport: Date = .distantPast

    let infiniteModeHistoryLimit = 40
    let infiniteMinSharedStyles = 2
    let infiniteMinSharedMoods = 2
    var gainPrefetchTask: Task<Void, Never>?
    var playbackLoadTask: Task<Void, Never>?
    var nowPlayingArtworkTask: Task<Void, Never>?
    var magicMixBuildTask: Task<Void, Never>?
    var magicMixSeedArtistKey: String? = nil
    var infiniteRefillTask: Task<Void, Never>?
    var preloadedNext: PreloadedNextTrack?
    var autoMixPlan: AutoMixPlan?
    var autoMixRecords: [AutoMixRecord] = []
    let mixTaps = NSMapTable<AVPlayerItem, AutoMixFilterTap>.weakToStrongObjects()
    var autoMixPlanTask: Task<Void, Never>?
    var autoMixTriggerTask: Task<Void, Never>?
    var autoMixTask: Task<Void, Never>?
    var autoMixInProgress = false
    var autoMixLyricsPrefetchKey: String?
    var mixOutgoingPlayer: AVQueuePlayer?
    var mixOutgoingLossless: LocalLosslessPlayer?
    var mixOutgoingVolume: Float = 1
    /// An AVPlayerItem can't move between players; its asset can.
    var mixReusableAsset: AVAsset?
    var mixPrepared: PreparedMixIncoming?
    var mixOutgoingOffset: TimeInterval = 0
    var mixIncomingGain: Float = 1
    var nextTrackPreloadTask: Task<Void, Never>?
    /// Timestamp of the most recent seek completion, used to suppress spurious
    /// AVPlayerItemDidPlayToEndTime notifications that race with seek callbacks.
    var lastSeekCompletedAt: Date?

    struct PreloadedNextTrack {
        enum Source {
            case local(codec: String?)
            case direct
            case hls(candidates: [URL], sessionID: String, shouldConstrain: Bool)
        }

        let ratingKey: String
        let streamURL: URL
        let source: Source
        let item: AVPlayerItem
        let detailedTrack: PlexMetadata?

        var hlsSessionID: String? {
            if case .hls(_, let sessionID, _) = source { return sessionID }
            return nil
        }
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var hasTrack: Bool { currentTrack != nil }

    var isTranscoding: Bool { isConstrainedPlaybackPath }

    var isPlayingLocalDownload: Bool { isPlayingLocalFile }

    var isPlayingLocalLossless: Bool {
        isPlayingLocalFile && ["FLAC", "ALAC"].contains(localFileCodec ?? "")
    }

    var activeStreamBitrate: Int? {
        guard hasTrack else { return nil }
        let media = currentTrack?.media?.first
        let audioStream = media?.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })
        let sourceBitrate = audioStream?.bitrate ?? media?.bitrate
        if isPlayingLocalFile,
           let track = currentTrack,
           let record = AppContext.shared.downloadManager.records[track.ratingKey],
           record.fileExtension != (media?.container ?? "").lowercased() {
            return record.averageBitrateKbps ?? sourceBitrate
        }
        if sourceBitrate == nil, isPlayingLocalFile, let track = currentTrack {
            return AppContext.shared.downloadManager.records[track.ratingKey]?.averageBitrateKbps
        }
        return sourceBitrate
    }

    var activeStreamCodec: String? {
        guard hasTrack else { return nil }
        if isPlayingLocalFile { return localFileCodec }
        if isConstrainedPlaybackPath { return "AAC" }
        let media = currentTrack?.media?.first
        let audioStream = media?.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })
        let raw = (audioStream?.codec ?? media?.audioCodec)?.lowercased()
        switch raw {
        case "flac": return "ALAC"  // FLAC is losslessly transcoded to ALAC via HLS
        case .some(let c): return c.uppercased()
        case nil: return nil
        }
    }

    func sourceAudioCodec(for track: PlexMetadata) -> String? {
        let media = track.media?.first
        let audioStream = media?.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })
        return (audioStream?.codec ?? media?.audioCodec)?.lowercased()
    }

    func sourceBitrate(for track: PlexMetadata) -> Int? {
        let media = track.media?.first
        let audioStream = media?.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })
        return audioStream?.bitrate ?? media?.bitrate
    }

    init() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoMix", isDirectory: true))
        try? fileManager.removeItem(at: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MixProfiles", isDirectory: true))
        setupAudioSession()
        setupRemoteCommands()
        restorePlaybackState()
        updateShuffleRepeatState()
        observeSoundCheckToggle()
        observeAudioRouteChanges()
        observeAudioInterruptions()
        observeNetworkChanges()
        refreshAirPlayConnectionState()
        AnimatedArtworkService.isAudioBuffered = { [weak self] in self?.isReadyForArtworkFetch ?? true }
    }

    @MainActor deinit {
        if let soundCheckObserver {
            NotificationCenter.default.removeObserver(soundCheckObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        if let audioInterruptionObserver {
            NotificationCenter.default.removeObserver(audioInterruptionObserver)
        }
        if let audioResumptionObserver {
            NotificationCenter.default.removeObserver(audioResumptionObserver)
        }
        if let networkChangeObserver {
            NotificationCenter.default.removeObserver(networkChangeObserver)
        }
        cancelAllBackgroundTasks()
        tearDownObservers()
    }

    func configure(server: PlexServer, client: PlexAPIClient) {
        self.server = server
        self.client = client
        Task { await TimelineOutbox.shared.flush(server: server, client: client) }
        if isInfiniteModeActive {
            maybeRefillInfiniteQueueIfNeeded(trigger: "configure")
        }
    }

    func updateCurrentTrackRating(_ userRating: Double?) {
        currentTrack?.userRating = userRating
        setLikeCommandActive((userRating ?? 0) >= 10)
    }

    @discardableResult
    func setFavorited(_ isFavorited: Bool, for track: PlexMetadata, server: PlexServer, client: PlexAPIClient, sectionId: String?) async -> Bool {
        let isCurrentTrack = track.ratingKey == currentTrack?.ratingKey
        if isCurrentTrack { updateCurrentTrackRating(isFavorited ? 10 : 0) }
        do {
            try await client.rateItem(server: server, ratingKey: track.ratingKey, rating: isFavorited ? 10 : -1)
            await client.refreshItem(server: server, ratingKey: track.ratingKey)
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            return true
        } catch {
            if isCurrentTrack { updateCurrentTrackRating(isFavorited ? 0 : 10) }
            return false
        }
    }

    func updateTrack(_ updated: PlexMetadata) {
        func merged(_ old: PlexMetadata) -> PlexMetadata {
            var track = updated
            track.playlistItemID = old.playlistItemID
            return track
        }
        if let current = currentTrack, current.ratingKey == updated.ratingKey {
            currentTrack = merged(current)
            lastPublishedNowPlayingTrackKey = nil
            updateNowPlayingInfo()
        }
        for i in queue.indices where queue[i].ratingKey == updated.ratingKey {
            queue[i] = merged(queue[i])
        }
        for i in originalQueue.indices where originalQueue[i].ratingKey == updated.ratingKey {
            originalQueue[i] = merged(originalQueue[i])
        }
    }

    func updateAlbumThumb(albumRatingKey: String, newThumb: String?) {
        if currentTrack?.parentRatingKey == albumRatingKey {
            currentTrack?.parentThumb = newThumb
        }
        for i in queue.indices where queue[i].parentRatingKey == albumRatingKey {
            queue[i].parentThumb = newThumb
        }
        for i in originalQueue.indices where originalQueue[i].parentRatingKey == albumRatingKey {
            originalQueue[i].parentThumb = newThumb
        }
    }

    // MARK: - Playback Control

    func play(tracks: [PlexMetadata], startingAt index: Int = 0) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else {
            logPlayback("play_request_rejected", "count=\(tracks.count) start=\(index)")
            return
        }
        logPlayback("play_request", "count=\(tracks.count) start=\(index) shuffled=\(isShuffled)")
        playbackIntent = true
        originalQueue = tracks
        if isShuffled {
            var shuffled = tracks
            let selected = shuffled.remove(at: index)
            shuffled.shuffle()
            shuffled.insert(selected, at: 0)
            queue = shuffled
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = index
        }
        prefetchGainMetadata()
        loadAndPlay(queue[currentIndex])
    }

    func togglePlayPause() {
        logPlayback("toggle_play_pause", "isPlaying=\(isPlaying)")
        if let losslessPlayer {
            toggleLosslessPlayback(losslessPlayer)
            return
        }
        if player == nil {
            logPlayback("toggle_recover", "reason=player_nil")
            recoverAndPlayCurrentTrackIfPossible()
            return
        }
        guard let player else { return }

        if player.currentItem == nil || player.currentItem?.status == .failed {
            logPlayback("toggle_recover", "reason=item_missing_or_failed")
            recoveryAttemptsForTrack = 0
            recoverAndPlayCurrentTrackIfPossible()
            return
        }

        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            playbackIntent = false
            logPlayback("paused")
            reportTimelineState("paused")
        } else {
            playbackIntent = true
            if isStuckWaitingForBuffer() {
                recoveryAttemptsForTrack = 0
                let resumeAt = preferredResumeTimeForRecovery()

                if let resumeAt {
                    logPlayback("toggle_recover", "reason=stuck_waiting resume_at=\(resumeAt)")
                } else {
                    logPlayback("toggle_recover", "reason=stuck_waiting")
                }
                recoverAndPlayCurrentTrackIfPossible(resumeAt: resumeAt)
                return
            }

            if let item = player.currentItem,
               item.status == .readyToPlay,
               item.duration.seconds.isFinite,
               CMTimeGetSeconds(item.currentTime()) >= item.duration.seconds - 0.5 {
                if streamTimeOffset > 0 {
                    seek(to: 0)
                    return
                }
                currentTime = 0
                let currentPlayer = player
                let generation = playbackGeneration
                currentPlayer.seek(to: .zero) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.playbackGeneration == generation else { return }
                        currentPlayer.play()
                    }
                }
                isPlaying = true
                logPlayback("resumed_from_end")
                reportTimelineState("playing")
                updateNowPlayingInfo()
                return
            }
            player.play()
            isPlaying = true
            logPlayback("resumed")
            reportTimelineState("playing")
        }
        updateNowPlayingInfo()
    }

    func playCurrent() {
        playbackIntent = true
        if let losslessPlayer {
            if !losslessPlayer.isPlaying { toggleLosslessPlayback(losslessPlayer) }
            return
        }
        if player == nil || player?.currentItem == nil || player?.currentItem?.status == .failed {
            recoverAndPlayCurrentTrackIfPossible()
            return
        }

        if let item = player?.currentItem,
           item.status == .readyToPlay,
           item.duration.seconds.isFinite,
           CMTimeGetSeconds(item.currentTime()) >= item.duration.seconds - 0.5 {
            if streamTimeOffset > 0 {
                seek(to: 0)
                return
            }
            guard let currentPlayer = player else { return }
            let generation = playbackGeneration
            currentPlayer.seek(to: .zero) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.playbackGeneration == generation else { return }
                    currentPlayer.play()
                }
            }
            isPlaying = true
            currentTime = 0
            updateNowPlayingInfo()
            return
        }
        guard let player else { return }
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pauseCurrent() {
        if let losslessPlayer {
            losslessPlayer.pause()
            isPlaying = false
            playbackIntent = false
            updateNowPlayingInfo()
            return
        }
        guard let player else { return }
        player.pause()
        isPlaying = false
        playbackIntent = false
        updateNowPlayingInfo()
    }

    var diagnosticsEnabled: Bool {
        #if DEBUG
        return UserDefaults.standard.object(forKey: Self.diagnosticsEnabledKey) as? Bool ?? true
        #else
        return false
        #endif
    }

    func logPlayback(_ event: String, _ details: @autoclosure () -> String = "") {
        #if DEBUG
        guard diagnosticsEnabled else { return }
        let trackKey = currentTrack?.ratingKey ?? "none"
        let prefix = "[AudioPlayer][\(event)] track=\(trackKey) idx=\(currentIndex)/\(max(queue.count - 1, 0))"
        let detailStr = details()
        if detailStr.isEmpty {
            print(prefix)
        } else {
            print("\(prefix) \(detailStr)")
        }
        #endif
    }

    var bestKnownPlaybackSeconds: TimeInterval {
        if let losslessPlayer { return losslessPlayer.currentTime }
        if let playerTime = player?.currentTime().seconds, playerTime.isFinite {
            return streamTimeOffset + playerTime
        }
        return currentTime
    }

    var isReadyForArtworkFetch: Bool {
        guard let item = player?.currentItem else { return true }
        if (item.asset as? AVURLAsset)?.url.isFileURL == true || isCurrentItemFullyBuffered { return true }
        let now = player?.currentTime().seconds ?? 0
        let ahead = item.loadedTimeRanges.reduce(0.0) { result, value in
            let range = value.timeRangeValue
            return max(result, CMTimeAdd(range.start, range.duration).seconds - now)
        }
        return ahead.isFinite && ahead >= 30
    }

    var isCurrentItemFullyBuffered: Bool {
        guard let item = player?.currentItem else { return false }
        if item.isPlaybackBufferFull { return true }
        let trackDuration = item.duration.seconds
        guard trackDuration.isFinite, trackDuration > 0 else { return false }
        let bufferedEnd = item.loadedTimeRanges.reduce(0.0) { result, value in
            let range = value.timeRangeValue
            let end = CMTimeAdd(range.start, range.duration).seconds
            return end.isFinite ? max(result, end) : result
        }
        return bufferedEnd >= trackDuration - 2
    }

    func preferredResumeTimeForRecovery() -> TimeInterval? {
        if currentTime.isFinite, currentTime > 2 {
            return currentTime
        }
        if let playerTime = player?.currentTime().seconds, playerTime.isFinite,
           streamTimeOffset + playerTime > 2 {
            return streamTimeOffset + playerTime
        }
        return nil
    }

    func isStuckWaitingForBuffer() -> Bool {
        guard let player else { return false }
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return false }
        guard player.reasonForWaitingToPlay == .toMinimizeStalls else { return false }
        guard let item = player.currentItem else { return false }
        return item.isPlaybackBufferEmpty || !item.isPlaybackLikelyToKeepUp
    }

    func recoverAndPlayCurrentTrackIfPossible(resumeAt: TimeInterval? = nil) {
        playbackIntent = true
        let effectiveResumeAt = resumeAt ?? pendingInitialSeekTime ?? preferredResumeTimeForRecovery()

        if queue.indices.contains(currentIndex) {
            if let effectiveResumeAt {
                logPlayback("recover_queue_track", "resume_at=\(effectiveResumeAt)")
            } else {
                logPlayback("recover_queue_track")
            }
            loadAndPlay(queue[currentIndex], resumeAt: effectiveResumeAt)
            return
        }
        if let track = currentTrack {
            if let effectiveResumeAt {
                logPlayback("recover_current_track_seed_queue", "resume_at=\(effectiveResumeAt)")
            } else {
                logPlayback("recover_current_track_seed_queue")
            }
            queue = [track]
            currentIndex = 0
            loadAndPlay(track, resumeAt: effectiveResumeAt)
            return
        }
        logPlayback("recover_failed", "reason=no_track_available")
    }

    func handlePlaybackFailure(_ reason: String) {
        guard let track = currentTrack else { return }
        guard playbackIntent else {
            logPlayback("recovery_ignored", "reason=\(reason) intent=false")
            return
        }

        if recoveryTrackRatingKey != track.ratingKey {
            recoveryTrackRatingKey = track.ratingKey
            recoveryAttemptsForTrack = 0
        }

        let resumeTime = preferredResumeTimeForRecovery()

        if isDirectStreamAttempt {
            logPlayback("recovery_fallback_to_hls", "reason=\(reason)")
            isDirectStreamAttempt = false
            loadAndPlay(track, resumeAt: resumeTime, forceHLS: true)
            return
        }

        if recoveryAttemptsForTrack < maxRecoveryAttemptsPerTrack {
            recoveryAttemptsForTrack += 1
            if let resumeTime {
                logPlayback("recovery_attempt", "reason=\(reason) attempt=\(recoveryAttemptsForTrack)/\(maxRecoveryAttemptsPerTrack) resume_at=\(resumeTime)")
            } else {
                logPlayback("recovery_attempt", "reason=\(reason) attempt=\(recoveryAttemptsForTrack)/\(maxRecoveryAttemptsPerTrack)")
            }
            recoverAndPlayCurrentTrackIfPossible(resumeAt: resumeTime)
            return
        }

        logPlayback("recovery_exhausted", "reason=\(reason) action=skip")
        if currentIndex < queue.count - 1 {
            currentIndex += 1
            loadAndPlay(queue[currentIndex])
            return
        }

        player?.pause()
        losslessPlayer?.pause()
        isPlaying = false
        playbackIntent = false
        updateNowPlayingInfo()
    }

    func next() {
        guard !queue.isEmpty else {
            logPlayback("next_ignored", "reason=empty_queue")
            return
        }
        if currentIndex < queue.count - 1 {
            currentIndex += 1
            logPlayback("next_advance", "to_index=\(currentIndex)")
        } else if isInfiniteModeActive {
            // Queue ran dry before refill completed — kick off a refill and
            // advance once tracks arrive (this is a rare race; refill normally
            // completes long before the current track finishes).
            requestInfiniteRefill()
            let expectedGeneration = playbackGeneration
            logPlayback("next_infinite_wait_for_refill")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.playbackGeneration == expectedGeneration,
                      self.isInfiniteModeActive,
                      self.currentIndex < self.queue.count - 1 else { return }
                self.currentIndex += 1
                self.loadAndPlay(self.queue[self.currentIndex])
            }
            return
        } else {
            player?.pause()
            losslessPlayer?.pause()
            losslessPlayer?.currentTime = 0
            isPlaying = false
            playbackIntent = false
            currentTime = 0
            player?.seek(to: .zero)
            updateNowPlayingInfo()
            logPlayback("next_stop_end_of_queue")
            reportTimelineState("stopped")
            return
        }
        loadAndPlay(queue[currentIndex])
    }

    func previous() {
        guard !queue.isEmpty else { return }
        let trimStart = currentTrackStartTime
        if currentTime - trimStart > 3 {
            seek(to: trimStart)
            return
        }
        if currentIndex > 0 {
            currentIndex -= 1
        }
        loadAndPlay(queue[currentIndex])
    }

    func advanceAfterTrackEnd() {
        if repeatMode != .off, queue.indices.contains(currentIndex) {
            consumeRepeatOnce()
            logPlayback("track_end_repeat", "mode=\(repeatMode.rawValue)")
            loadAndPlay(queue[currentIndex])
            return
        }
        next()
    }

    func consumeRepeatOnce() {
        guard repeatMode == .once else { return }
        repeatMode = .off
        savePlaybackState()
        updateShuffleRepeatState()
    }

    func seek(to time: TimeInterval) {
        let boundedTime = max(0, duration > 0 ? min(time, duration) : time)

        if losslessPlayer != nil {
            seekLossless(to: boundedTime)
            return
        }

        if !isPlayingLocalFile, !isDirectStreamAttempt, server != nil, player != nil,
           queue.indices.contains(currentIndex) {
            logPlayback("seek_restart_stream", "target=\(boundedTime)")
            recoveryAttemptsForTrack = 0
            currentTime = boundedTime
            loadAndPlay(queue[currentIndex], resumeAt: boundedTime)
            return
        }

        guard let player else {
            pendingInitialSeekTime = boundedTime
            currentTime = boundedTime
            logPlayback("seek_queued", "reason=player_nil target=\(boundedTime)")
            return
        }
        guard isReadyToPlay else {
            pendingInitialSeekTime = boundedTime
            currentTime = boundedTime
            logPlayback("seek_queued", "reason=not_ready target=\(boundedTime)")
            return
        }
        recoveryAttemptsForTrack = 0
        isSeeking = true
        currentTime = boundedTime

        let target = CMTime(seconds: boundedTime, preferredTimescale: 600)
        let tolerance = isPlayingLocalLossless ? CMTime.zero : CMTime(seconds: 0.05, preferredTimescale: 600)
        let seekGeneration = playbackGeneration
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeeking = false
                self.lastSeekCompletedAt = Date()
                guard self.playbackGeneration == seekGeneration, finished else { return }
                self.currentTime = boundedTime
                self.updateNowPlayingInfo()
                self.reportTimelineState(self.isPlaying ? "playing" : "paused")
            }
        }
    }

    func seekToProgress(_ progress: Double) {
        let time = progress * duration
        seek(to: time)
    }

    // MARK: - Private

    func cancelAllBackgroundTasks() {
        playbackLoadTask?.cancel()
        nowPlayingArtworkTask?.cancel()
        gainPrefetchTask?.cancel()
        magicMixBuildTask?.cancel()
        infiniteRefillTask?.cancel()
        networkRecoveryTask?.cancel()
        nextTrackPreloadTask?.cancel()
        heldSeekTask?.cancel()
        cancelAutoMixPlanning()
        finishAutoMix()
        playbackLoadTask = nil
        nowPlayingArtworkTask = nil
        gainPrefetchTask = nil
        magicMixBuildTask = nil
        infiniteRefillTask = nil
        networkRecoveryTask = nil
        nextTrackPreloadTask = nil
        heldSeekTask = nil
    }

    var currentTrackStartTime: TimeInterval {
        currentTrack.flatMap { AppContext.shared.trackMarkers.start(for: $0.ratingKey) } ?? 0
    }

    func makePlayerItem(url: URL, trimmedTo track: PlexMetadata? = nil, streamOffset: TimeInterval = 0, asset: AVAsset? = nil) -> AVPlayerItem {
        let item = asset.map { AVPlayerItem(asset: $0) } ?? AVPlayerItem(url: url)
        attachMixFilter(to: item, url: url)
        if let track, streamOffset == 0,
           let stop = AppContext.shared.trackMarkers.stop(for: track.ratingKey) {
            item.forwardPlaybackEndTime = CMTime(seconds: stop, preferredTimescale: 600)
        }
        return item
    }

    enum PlaybackPath {
        case lan
        case wan
        case relay
        case cellular

        var locationQueryValue: String {
            switch self {
            case .lan: "lan"
            case .wan: "wan"
            case .relay: "relay"
            case .cellular: "cellular"
            }
        }

    }

    func loadAndPlay(_ track: PlexMetadata, resumeAt requestedResume: TimeInterval? = nil, forceHLS: Bool = false) {
        let resumeAt = requestedResume ?? AppContext.shared.trackMarkers.start(for: track.ratingKey)
        guard server != nil, client != nil else {
            logPlayback("load_failed", "reason=server_or_client_not_configured requested=\(track.ratingKey)")
            return
        }

        pendingInitialSeekTime = nil
        streamTimeOffset = 0
        pendingStreamOffsetCalibration = false
        cancelAutoMixPlanning()
        if let resumeAt {
            logPlayback("load_begin", "requested=\(track.ratingKey) queue_count=\(queue.count) resume_at=\(resumeAt)")
        } else {
            logPlayback("load_begin", "requested=\(track.ratingKey) queue_count=\(queue.count)")
        }

        if currentTrack != nil {
            reportTimelineState("stopped", continuing: true)
        }
        if repeatMode == .once, let currentTrack, currentTrack.ratingKey != track.ratingKey {
            repeatMode = .off
            updateShuffleRepeatState()
        }

        currentTrack = track
        if recoveryTrackRatingKey != track.ratingKey {
            recoveryTrackRatingKey = track.ratingKey
            recoveryAttemptsForTrack = 0
        }
        playbackGeneration += 1
        isReadyToPlay = false
        duration = Double(track.duration ?? 0) / 1000.0
        let boundedResume: TimeInterval? = resumeAt.map { max(0, duration > 0 ? min($0, duration) : $0) }
        currentTime = boundedResume ?? 0
        universalStreamURL = nil
        universalCandidatesForCurrentItem = []
        universalCandidateIndexForCurrentItem = 0
        currentSessionID = UUID().uuidString
        isConstrainedPlaybackPath = false
        isPlayingLocalFile = false
        localFileCodec = nil

        guard let server, let client else { return }

        tearDownObservers()
        stopLosslessPlayback()
        if let outgoing = player, playbackIntent, outgoing.timeControlStatus == .playing {
            // Keep the outgoing player running, muted, until the new item takes over.
            // Pausing it now leaves nothing playing while the stream is set up, and
            // CarPlay flashes paused on every skip. startPlayback() stops it.
            outgoing.volume = 0
        } else {
            player?.pause()
            player?.removeAllItems()
        }

        if let localURL = AppContext.shared.downloadManager.localURL(for: track.ratingKey) {
            discardPreloadedNext()
            logPlayback("load_local_file", "track=\(track.ratingKey)")
            isPlayingLocalFile = true
            localFileCodec = AppContext.shared.downloadManager.records[track.ratingKey]?
                .codecLabel(source: track.media?.first)
            currentSessionID = nil
            if Self.isLosslessLabel(localFileCodec),
               startLosslessPlayback(url: localURL, resumeAt: boundedResume) {
                return
            }
            pendingInitialSeekTime = boundedResume
            startPlayback(url: localURL)
            return
        }

        let sourceCodec = sourceAudioCodec(for: track)
        let disableCellularTranscoding = UserDefaults.standard.bool(forKey: Self.disableCellularTranscodingKey)
        let cellularTranscodeBitrate = Self.cellularTranscodeBitrateKbps
        let playbackPath = resolvedPlaybackPath(for: server)
        let isConstrainedNetworkPath: Bool
        switch playbackPath {
        case .cellular, .wan, .relay:
            isConstrainedNetworkPath = !disableCellularTranscoding
        case .lan:
            isConstrainedNetworkPath = false
        }
        let sourceExceedsTarget = sourceBitrate(for: track).map { $0 > cellularTranscodeBitrate } ?? true
        let shouldConstrainForNetwork = isConstrainedNetworkPath && sourceExceedsTarget

        if !forceHLS, !shouldConstrainForNetwork, sourceCodec != "flac",
           let partKey = track.media?.first?.part?.first?.key,
           let directURL = client.directStreamURL(server: server, partKey: partKey) {
            discardPreloadedNext()
            isDirectStreamAttempt = true
            isConstrainedPlaybackPath = false
            currentSessionID = nil
            pendingInitialSeekTime = boundedResume
            logPlayback("load_direct_stream", "codec=\(sourceCodec ?? "?")")
            startPlayback(url: directURL)
            return
        }
        isDirectStreamAttempt = false

        if boundedResume != nil {
            discardPreloadedNext()
        }

        if let preloaded = consumePreloadedNextTrack(for: track.ratingKey),
           case .hls(let candidates, let sessionID, let shouldConstrain) = preloaded.source {
            universalCandidatesForCurrentItem = candidates
            universalCandidateIndexForCurrentItem = 0
            universalStreamURL = preloaded.streamURL
            currentSessionID = sessionID
            isConstrainedPlaybackPath = shouldConstrain
            if let detailed = preloaded.detailedTrack {
                detailedTrackForSoundCheck = detailed
            }
            logPlayback("load_using_preload", "track=\(track.ratingKey)")
            startPlayback(url: preloaded.streamURL)
            return
        }

        let preferAACTranscode = shouldConstrainForNetwork
        let avoidAudioTranscode = !preferAACTranscode

        guard let sessionID = currentSessionID else {
            logPlayback("load_rejected", "reason=missing_session_id")
            player?.pause()
            return
        }
        let metadataPath = track.key ?? "/library/metadata/\(track.ratingKey)"
        let normalizedPath = metadataPath.hasPrefix("/") ? metadataPath : "/\(metadataPath)"
        let mediaPathCandidates = [normalizedPath]
        let headers = client.playbackHeaders(
            server: server,
            sessionID: sessionID,
            preferAACTranscode: preferAACTranscode,
            avoidAudioTranscode: avoidAudioTranscode,
            sourceCodec: sourceAudioCodec(for: track)
        )
        isConstrainedPlaybackPath = shouldConstrainForNetwork

        var offsetSeconds = 0
        if let boundedResume, boundedResume > 0 {
            let safeUpper = duration > 1 ? duration - 1 : boundedResume
            offsetSeconds = Int(min(boundedResume, safeUpper))
        }
        streamTimeOffset = TimeInterval(offsetSeconds)
        pendingStreamOffsetCalibration = streamTimeOffset > 0
        currentTime = streamTimeOffset > 0 ? streamTimeOffset : currentTime

        let generation = playbackGeneration
        let capturedClient = client
        let capturedServer = server
        let capturedOffsetSeconds = offsetSeconds

        let soundCheckEnabled = UserDefaults.standard.bool(forKey: Self.soundCheckKey)
        let ratingKey = track.ratingKey

        playbackLoadTask?.cancel()
        playbackLoadTask = Task {
            async let decisionResult: Void = capturedClient.universalDecision(
                server: capturedServer,
                metadataPath: normalizedPath,
                sessionID: sessionID,
                headers: headers,
                location: playbackPath.locationQueryValue,
                constrainAudioBitrate: shouldConstrainForNetwork,
                cellularTranscodeBitrate: cellularTranscodeBitrate,
                offsetSeconds: capturedOffsetSeconds
            )
            async let detailedTrack: PlexMetadata? = soundCheckEnabled
                ? (try? await capturedClient.cachedMetadata(server: capturedServer, ratingKey: ratingKey))
                : nil

            do {
                try await decisionResult
            } catch {
                guard !Task.isCancelled else { return }
                guard self.playbackGeneration == generation else { return }
                self.logPlayback("decision_failed", "error=\(error.localizedDescription)")
                self.handlePlaybackFailure("decision_failed")
                return
            }

            self.detailedTrackForSoundCheck = await detailedTrack

            guard !Task.isCancelled else { return }
            guard self.playbackGeneration == generation else { return }

            let candidates = capturedClient.universalStreamURLCandidates(
                server: capturedServer,
                mediaPathCandidates: mediaPathCandidates,
                sessionID: sessionID,
                location: playbackPath.locationQueryValue,
                constrainAudioBitrate: shouldConstrainForNetwork,
                cellularTranscodeBitrate: cellularTranscodeBitrate,
                offsetSeconds: capturedOffsetSeconds
            )

            guard let masterURL = candidates.first else {
                self.logPlayback("universal_url_unavailable")
                self.player?.pause()
                self.isPlaying = false
                return
            }
            let resolvedURL = await capturedClient.resolveUniversalVariantURL(masterURL: masterURL) ?? masterURL
            guard !Task.isCancelled else { return }
            guard self.playbackGeneration == generation else { return }
            if resolvedURL == masterURL {
                self.logPlayback("variant_resolve_failed", "using master playlist")
            }
            self.universalCandidatesForCurrentItem = candidates
            self.universalCandidateIndexForCurrentItem = 0
            self.universalStreamURL = resolvedURL
            self.logPlayback("load_ready")
            self.startPlayback(url: resolvedURL)
        }
    }

    func startPlayback(url: URL) {
        logPlayback("start_playback", "path=\(url.path)")
        let reusable = mixReusableAsset.flatMap { ($0 as? AVURLAsset)?.url == url ? $0 : nil }
        mixReusableAsset = nil
        let prepared = mixPrepared.flatMap { $0.url == url && $0.ratingKey == currentTrack?.ratingKey ? $0 : nil }
        mixPrepared = nil
        let item = prepared?.item ?? makePlayerItem(url: url, trimmedTo: currentTrack, streamOffset: streamTimeOffset, asset: reusable)
        if !isPlayingLocalFile {
            item.preferredForwardBufferDuration = preferredFullTrackBufferDuration(for: duration)
        }
        player?.pause()
        player?.removeAllItems()
        let queuePlayer = prepared?.player ?? AVQueuePlayer(playerItem: item)
        if let prepared {
            let position = prepared.item.currentTime().seconds
            if let target = pendingInitialSeekTime, !(position.isFinite && abs(position - target) < 0.5) {
                logPlayback("automix_prepared_seek_missed", "at=\(position) target=\(target)")
            } else {
                logPlayback("automix_prepared_start", "at=\(position)")
                pendingInitialSeekTime = nil
            }
        }
        queuePlayer.actionAtItemEnd = .none
        player = queuePlayer
        player?.automaticallyWaitsToMinimizeStalling = !isPlayingLocalFile
        player?.volume = soundCheckVolume(for: currentTrack)

        if pendingInitialSeekTime == nil, playbackIntent {
            player?.play()
            isPlaying = true
        } else if pendingInitialSeekTime == nil {
            isPlaying = false
        }

        beginTrackSession(item: item)
    }

    func beginTrackSession(item: AVPlayerItem) {
        observeItemStatus(item)
        observePlayerState()
        observeQueueAdvance()
        observePlaybackFailures(item)
        addTimeObserver()
        observeTrackEnd(item)
        updateNowPlayingInfo()
        prefetchGainMetadata()
        prefetchUpcomingArtwork()
        maybeRefillInfiniteQueueIfNeeded(trigger: "start_playback")
        syncDynamicQueueDownloads()
        reportTimelineState(isPlaying ? "playing" : "paused")
        savePlaybackState()
        watchForStalledStart()
    }

    func preferredFullTrackBufferDuration(for known: TimeInterval) -> TimeInterval {
        let target = known > 0 ? known + 30 : 600
        return min(target, 1800)
    }

}
