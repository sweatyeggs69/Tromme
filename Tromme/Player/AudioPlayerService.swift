import AVFoundation
import MediaPlayer
import Network
import Observation

@Observable @MainActor
final class AudioPlayerService: @unchecked Sendable {
    var currentTrack: PlexMetadata?
    var queue: [PlexMetadata] = []
    var currentIndex: Int = 0
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShuffled = false
    var repeatMode: RepeatMode = .off
    var isMagicMixActive = false
    var isInfiniteModeActive = false
    /// True once the current item's status is .readyToPlay.
    var isReadyToPlay = false
    /// True when the active audio output route is AirPlay.
    var isAirPlayConnected = false
    /// True when the active audio output route is CarPlay.
    var isCarPlayConnected = false

    enum RepeatMode: String, Sendable {
        case off, all, one

        var iconName: String {
            switch self {
            case .off, .all: "repeat"
            case .one: "repeat.1"
            }
        }

        var isActive: Bool { self != .off }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var trackEndObserver: Any?
    private var playbackStalledObserver: Any?
    private var itemFailedToEndObserver: Any?
    private var playbackGeneration: Int = 0
    private let maxRecoveryAttemptsPerTrack = 2
    private let scrobbleThreshold: Double = 0.9
    private var recoveryTrackRatingKey: String?
    private var recoveryAttemptsForTrack = 0
    private var server: PlexServer?
    private var client: PlexAPIClient?
    private var originalQueue: [PlexMetadata] = []
    private var universalStreamURL: URL?
    private var universalCandidatesForCurrentItem: [URL] = []
    private var universalCandidateIndexForCurrentItem = 0
    private var currentSessionID: String?
    private var detailedTrackForSoundCheck: PlexMetadata?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkThumbPath: String?
    private var isConstrainedPlaybackPath = false
    private var isCellular: Bool { NetworkStatus.shared.isCellular }
    private var isSeeking = false
    private var soundCheckObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var audioInterruptionObserver: NSObjectProtocol?
    private var wasInterruptedWhilePlaying = false
    private var networkChangeObserver: NSObjectProtocol?
    private var networkRecoveryTask: Task<Void, Never>?
    private var lastNetworkInterfaceType: NWInterface.InterfaceType?
    private var lastNetworkIsConnected: Bool = true
    private var isNetworkRecovering: Bool = false
    #if DEBUG
    private var lastLoggedTimeControlStatus: AVPlayer.TimeControlStatus?
    #endif
    private var pendingInitialSeekTime: TimeInterval?
    private var scrobbledTrackRatingKey: String?
    private var gainPrefetchTask: Task<Void, Never>?
    private var playbackLoadTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var magicMixRefillTask: Task<Void, Never>?
    private var magicMixPreviousKeys: Set<String> = []
    private var infiniteRefillTask: Task<Void, Never>?
    private var infinitePreviousKeys: Set<String> = []
    private var preloadedNext: PreloadedNextTrack?
    private var nextTrackPreloadTask: Task<Void, Never>?

    private struct PreloadedNextTrack {
        let ratingKey: String
        let streamURL: URL
        let candidates: [URL]
        let sessionID: String
        let shouldConstrain: Bool
    }

    /// Progress from 0 to 1
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var hasTrack: Bool { currentTrack != nil }

    init() {
        setupAudioSession()
        setupRemoteCommands()
        restorePlaybackState()
        updateShuffleRepeatState()
        observeSoundCheckToggle()
        observeAudioRouteChanges()
        observeAudioInterruptions()
        observeNetworkChanges()
        refreshAirPlayConnectionState()
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
        if let networkChangeObserver {
            NotificationCenter.default.removeObserver(networkChangeObserver)
        }
        cancelAllBackgroundTasks()
        tearDownObservers()
    }

    func configure(server: PlexServer, client: PlexAPIClient) {
        self.server = server
        self.client = client
    }

    // MARK: - Playback Control

    func play(tracks: [PlexMetadata], startingAt index: Int = 0) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else {
            logPlayback("play_request_rejected", "count=\(tracks.count) start=\(index)")
            return
        }
        logPlayback("play_request", "count=\(tracks.count) start=\(index) shuffled=\(isShuffled)")
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
        if player == nil {
            logPlayback("toggle_recover", "reason=player_nil")
            recoverAndPlayCurrentTrackIfPossible()
            return
        }
        guard let player else { return }

        if player.currentItem == nil || player.currentItem?.status == .failed {
            logPlayback("toggle_recover", "reason=item_missing_or_failed")
            recoverAndPlayCurrentTrackIfPossible()
            return
        }

        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            logPlayback("paused")
            reportTimelineState("paused")
        } else {
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

            // If the item has finished playing, seek to start before resuming
            if let item = player.currentItem,
               item.status == .readyToPlay,
               item.duration.seconds.isFinite,
               CMTimeGetSeconds(item.currentTime()) >= item.duration.seconds - 0.5 {
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

    private func playCurrent() {
        if player == nil || player?.currentItem == nil || player?.currentItem?.status == .failed {
            recoverAndPlayCurrentTrackIfPossible()
            return
        }

        // If the player item has ended (song finished), re-seek to start before playing
        if let item = player?.currentItem,
           item.status == .readyToPlay,
           item.duration.seconds.isFinite,
           CMTimeGetSeconds(item.currentTime()) >= item.duration.seconds - 0.5 {
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

    private func pauseCurrent() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    private var diagnosticsEnabled: Bool {
        #if DEBUG
        return UserDefaults.standard.object(forKey: Self.diagnosticsEnabledKey) as? Bool ?? true
        #else
        return false
        #endif
    }

    private func logPlayback(_ event: String, _ details: @autoclosure () -> String = "") {
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

    private var bestKnownPlaybackSeconds: TimeInterval {
        if let playerTime = player?.currentTime().seconds, playerTime.isFinite {
            return playerTime
        }
        return currentTime
    }

    private var isCurrentItemFullyBuffered: Bool {
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

    private func preferredResumeTimeForRecovery() -> TimeInterval? {
        if currentTime.isFinite, currentTime > 2 {
            return currentTime
        }
        if let playerTime = player?.currentTime().seconds, playerTime.isFinite, playerTime > 2 {
            return playerTime
        }
        return nil
    }

    private func isStuckWaitingForBuffer() -> Bool {
        guard let player else { return false }
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return false }
        guard player.reasonForWaitingToPlay == .toMinimizeStalls else { return false }
        guard let item = player.currentItem else { return false }
        return item.isPlaybackBufferEmpty || !item.isPlaybackLikelyToKeepUp
    }

    private func recoverAndPlayCurrentTrackIfPossible(resumeAt: TimeInterval? = nil) {
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

    private func handlePlaybackFailure(_ reason: String) {
        guard let track = currentTrack else { return }
        guard isPlaying else {
            logPlayback("recovery_ignored", "reason=\(reason) playback_inactive=true")
            return
        }

        if recoveryTrackRatingKey != track.ratingKey {
            recoveryTrackRatingKey = track.ratingKey
            recoveryAttemptsForTrack = 0
        }

        let resumeTime = preferredResumeTimeForRecovery()

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
        if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            loadAndPlay(queue[currentIndex])
            return
        }

        isPlaying = false
        updateNowPlayingInfo()
    }

    func next() {
        guard !queue.isEmpty else {
            logPlayback("next_ignored", "reason=empty_queue")
            return
        }
        if repeatMode == .one {
            logPlayback("next_repeat_one_reload")
            loadAndPlay(queue[currentIndex])
            return
        }
        if currentIndex < queue.count - 1 {
            currentIndex += 1
            logPlayback("next_advance", "to_index=\(currentIndex)")
        } else if repeatMode == .all {
            currentIndex = 0
            logPlayback("next_wrap", "to_index=0")
        } else {
            player?.pause()
            isPlaying = false
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
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        }
        loadAndPlay(queue[currentIndex])
    }

    func seek(to time: TimeInterval) {
        let boundedTime = max(0, duration > 0 ? min(time, duration) : time)
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
        isSeeking = true
        currentTime = boundedTime

        let target = CMTime(seconds: boundedTime, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeeking = false
                guard finished else { return }
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

    func addToQueue(_ track: PlexMetadata) {
        let insertIndex = currentIndex + 1
        queue.insert(track, at: min(insertIndex, queue.count))
        originalQueue.append(track)
        savePlaybackState()
    }

    func addToEndOfQueue(_ track: PlexMetadata) {
        queue.append(track)
        originalQueue.append(track)
        savePlaybackState()
    }

    func removeFromQueue(at index: Int) {
        let queueIndex = currentIndex + 1 + index
        guard queueIndex < queue.count else { return }
        let track = queue.remove(at: queueIndex)
        if let origIndex = originalQueue.firstIndex(where: { $0.ratingKey == track.ratingKey }) {
            originalQueue.remove(at: origIndex)
        }
        savePlaybackState()
    }

    func playFromQueue(at index: Int) {
        let queueIndex = currentIndex + 1 + index
        guard queueIndex < queue.count else { return }
        let track = queue.remove(at: queueIndex)
        queue.insert(track, at: currentIndex + 1)
        currentIndex += 1
        loadAndPlay(queue[currentIndex])
    }

    /// Jump to an upcoming track by offset without reordering the queue.
    func skipToUpcoming(at offset: Int) {
        let queueIndex = currentIndex + 1 + offset
        guard queue.indices.contains(queueIndex) else { return }
        currentIndex = queueIndex
        loadAndPlay(queue[currentIndex])
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        var upcoming = Array(queue[(currentIndex + 1)...])
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange((currentIndex + 1)..., with: upcoming)
    }

    func toggleShuffle() {
        // If queue is empty but we have a current track (e.g. restored state), seed the queue
        if queue.isEmpty, let track = currentTrack {
            queue = [track]
            originalQueue = [track]
            currentIndex = 0
        }
        guard !queue.isEmpty else { return }
        isShuffled.toggle()
        if isShuffled {
            let current = queue[currentIndex]
            var remaining = queue
            remaining.remove(at: currentIndex)
            remaining.shuffle()
            remaining.insert(current, at: 0)
            queue = remaining
            currentIndex = 0
        } else {
            if let current = currentTrack,
               let idx = originalQueue.firstIndex(where: { $0.ratingKey == current.ratingKey }) {
                queue = originalQueue
                currentIndex = idx
            }
        }
        savePlaybackState()
        updateShuffleRepeatState()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        savePlaybackState()
        updateShuffleRepeatState()
    }

    func shuffleUpcomingQueue() {
        guard currentIndex + 1 < queue.count else { return }
        var upcoming = Array(queue[(currentIndex + 1)...])
        upcoming.shuffle()
        queue.replaceSubrange((currentIndex + 1)..., with: upcoming)
    }

    // MARK: - Queue Info

    var upcomingTracks: [PlexMetadata] {
        guard !queue.isEmpty, currentIndex + 1 < queue.count else { return [] }
        return Array(queue[(currentIndex + 1)...])
    }

    func clearQueue() {
        guard !queue.isEmpty else { return }
        if let currentTrack {
            queue = [currentTrack]
            originalQueue = [currentTrack]
            currentIndex = 0
        } else if queue.indices.contains(currentIndex) {
            let track = queue[currentIndex]
            queue = [track]
            originalQueue = [track]
            currentIndex = 0
        } else {
            queue = []
            originalQueue = []
            currentIndex = 0
        }
        savePlaybackState()
    }

    func resetPlayback() {
        playbackGeneration += 1
        cancelAllBackgroundTasks()
        discardPreloadedNext()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        tearDownObservers()
        queue = []
        originalQueue = []
        currentIndex = 0
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isMagicMixActive = false
        isInfiniteModeActive = false
        magicMixPreviousKeys.removeAll()
        infinitePreviousKeys.removeAll()
        isReadyToPlay = false
        stopActiveTranscodeSession()
        currentSessionID = nil
        pendingInitialSeekTime = nil
        universalStreamURL = nil
        universalCandidatesForCurrentItem = []
        universalCandidateIndexForCurrentItem = 0
        detailedTrackForSoundCheck = nil
        cachedArtwork = nil
        cachedArtworkThumbPath = nil
        isConstrainedPlaybackPath = false
        savePlaybackState()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Private

    private func cancelAllBackgroundTasks() {
        playbackLoadTask?.cancel()
        nowPlayingArtworkTask?.cancel()
        gainPrefetchTask?.cancel()
        magicMixRefillTask?.cancel()
        infiniteRefillTask?.cancel()
        networkRecoveryTask?.cancel()
        nextTrackPreloadTask?.cancel()
        playbackLoadTask = nil
        nowPlayingArtworkTask = nil
        gainPrefetchTask = nil
        magicMixRefillTask = nil
        infiniteRefillTask = nil
        networkRecoveryTask = nil
        nextTrackPreloadTask = nil
    }

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        AVPlayerItem(url: url)
    }

    private enum PlaybackPath {
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

        var isRemote: Bool {
            switch self {
            case .lan: false
            case .wan, .relay, .cellular: true
            }
        }
    }

    private func loadAndPlay(_ track: PlexMetadata, resumeAt: TimeInterval? = nil) {
        guard server != nil, client != nil else {
            logPlayback("load_failed", "reason=server_or_client_not_configured requested=\(track.ratingKey)")
            return
        }

        pendingInitialSeekTime = resumeAt
        if let resumeAt {
            logPlayback("load_begin", "requested=\(track.ratingKey) queue_count=\(queue.count) resume_at=\(resumeAt)")
        } else {
            logPlayback("load_begin", "requested=\(track.ratingKey) queue_count=\(queue.count)")
        }

        // Report stopped for the previous track before switching
        if currentTrack != nil {
            reportTimelineState("stopped", continuing: true)
        }

        currentTrack = track
        if recoveryTrackRatingKey != track.ratingKey {
            recoveryTrackRatingKey = track.ratingKey
            recoveryAttemptsForTrack = 0
        }
        if scrobbledTrackRatingKey != track.ratingKey {
            scrobbledTrackRatingKey = nil
        }
        playbackGeneration += 1
        isReadyToPlay = false
        duration = Double(track.duration ?? 0) / 1000.0
        if let resumeAt {
            let boundedResume = max(0, duration > 0 ? min(resumeAt, duration) : resumeAt)
            currentTime = boundedResume
        } else {
            currentTime = 0
        }
        universalStreamURL = nil
        universalCandidatesForCurrentItem = []
        universalCandidateIndexForCurrentItem = 0
        stopActiveTranscodeSession()
        currentSessionID = UUID().uuidString
        isConstrainedPlaybackPath = false

        guard let server, let client else { return }

        tearDownObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)

        // Fast path: use preloaded next track URL/session if it matches.
        // Saves the universalDecision API round-trip on track transitions.
        if let preloaded = consumePreloadedNextTrack(for: track.ratingKey) {
            universalCandidatesForCurrentItem = preloaded.candidates
            universalCandidateIndexForCurrentItem = 0
            universalStreamURL = preloaded.streamURL
            currentSessionID = preloaded.sessionID
            isConstrainedPlaybackPath = preloaded.shouldConstrain
            logPlayback("load_using_preload", "track=\(track.ratingKey)")
            startPlayback(url: preloaded.streamURL)
            return
        }

        let disableCellularTranscoding = UserDefaults.standard.bool(forKey: Self.disableCellularTranscodingKey)
        let cellularTranscodeBitrate = Self.validatedCellularTranscodeBitrate(
            UserDefaults.standard.integer(forKey: Self.cellularTranscodeBitrateKbpsKey)
        )
        let shouldConstrainConstrainedPaths = !disableCellularTranscoding
        let playbackPath = resolvedPlaybackPath(for: server)
        let shouldConstrainForNetwork: Bool
        switch playbackPath {
        case .cellular, .wan, .relay:
            shouldConstrainForNetwork = shouldConstrainConstrainedPaths
        case .lan:
            shouldConstrainForNetwork = false
        }
        let preferAACTranscode = shouldConstrainForNetwork
        let avoidAudioTranscode = !preferAACTranscode

        // Always route audio through Plex universal HLS for stable seek/duration behavior.
        guard let sessionID = currentSessionID else {
            logPlayback("load_rejected", "reason=missing_session_id")
            return
        }
        let metadataPath = track.key ?? "/library/metadata/\(track.ratingKey)"
        let normalizedPath = metadataPath.hasPrefix("/") ? metadataPath : "/\(metadataPath)"
        let mediaPathCandidates = [normalizedPath]
        let headers = client.playbackHeaders(
            server: server,
            sessionID: sessionID,
            preferAACTranscode: preferAACTranscode,
            avoidAudioTranscode: avoidAudioTranscode
        )
        isConstrainedPlaybackPath = shouldConstrainForNetwork
        let generation = playbackGeneration
        let capturedClient = client
        let capturedServer = server

        let soundCheckEnabled = UserDefaults.standard.bool(forKey: Self.soundCheckKey)
        let ratingKey = track.ratingKey

        playbackLoadTask?.cancel()
        playbackLoadTask = Task {
            // Step 1: Authorize transcode session and fetch detailed metadata (for gain) in parallel.
            async let decisionResult: Void = capturedClient.universalDecision(
                server: capturedServer,
                metadataPath: normalizedPath,
                sessionID: sessionID,
                headers: headers,
                location: playbackPath.locationQueryValue,
                constrainAudioBitrate: shouldConstrainForNetwork,
                cellularTranscodeBitrate: cellularTranscodeBitrate
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

            // Step 2: Build universal HLS URL and play directly.
            let candidates = capturedClient.universalStreamURLCandidates(
                server: capturedServer,
                mediaPathCandidates: mediaPathCandidates,
                sessionID: sessionID,
                location: playbackPath.locationQueryValue,
                constrainAudioBitrate: shouldConstrainForNetwork,
                cellularTranscodeBitrate: cellularTranscodeBitrate
            )

            guard let streamURL = candidates.first else {
                self.logPlayback("universal_url_unavailable")
                self.isPlaying = false
                return
            }
            guard !Task.isCancelled else { return }
            guard self.playbackGeneration == generation else { return }
            self.universalCandidatesForCurrentItem = candidates
            self.universalCandidateIndexForCurrentItem = 0
            self.universalStreamURL = streamURL
            self.logPlayback("load_ready")
            self.startPlayback(url: streamURL)
        }
    }

    private func startPlayback(url: URL) {
        logPlayback("start_playback", "path=\(url.path)")
        let item = makePlayerItem(url: url)
        item.preferredForwardBufferDuration = preferredFullTrackBufferDuration()
        player = AVPlayer(playerItem: item)
        player?.automaticallyWaitsToMinimizeStalling = true
        player?.volume = soundCheckVolume(for: currentTrack)
        player?.play()
        isPlaying = true

        observeItemStatus(item)
        observePlayerState()
        observePlaybackFailures(item)
        addTimeObserver()
        observeTrackEnd()
        updateNowPlayingInfo()
        prefetchGainMetadata()
        prefetchUpcomingArtwork()
        maybeRefillMagicMixQueueIfNeeded(trigger: "start_playback")
        maybeRefillInfiniteQueueIfNeeded(trigger: "start_playback")
        reportTimelineState("playing")
        savePlaybackState()
    }

    private func maybeRefillMagicMixQueueIfNeeded(trigger: String) {
        guard isMagicMixActive else { return }
        guard upcomingTracks.count <= 5 else { return }
        guard magicMixRefillTask == nil else { return }
        guard let server, let client else { return }
        guard let sectionId = AppContext.shared.serverConnection?.currentLibrarySectionId else { return }
        guard let currentTrack, let seedAlbumKey = currentTrack.parentRatingKey else { return }

        let seedTrackKey = currentTrack.ratingKey
        let seedArtistKey = currentTrack.grandparentRatingKey
        let styleMatch = max(UserDefaults.standard.integer(forKey: "magicMixStyleMatch"), 1)

        logPlayback("magic_mix_refill_begin", "trigger=\(trigger) upcoming=\(upcomingTracks.count)")

        magicMixRefillTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.magicMixRefillTask = nil
                }
            }

            guard let self else { return }
            let allTracks = (try? await client.magicMixTracks(
                server: server,
                sectionId: sectionId,
                seedTrackKey: seedTrackKey,
                seedAlbumKey: seedAlbumKey,
                seedArtistKey: seedArtistKey,
                limit: 100,
                minMatchingStyles: styleMatch
            )) ?? []

            guard !Task.isCancelled else { return }
            guard !allTracks.isEmpty else {
                await MainActor.run {
                    self.logPlayback("magic_mix_refill_empty", "trigger=\(trigger)")
                }
                return
            }

            let selected: [PlexMetadata] = await MainActor.run {
                let fresh = allTracks.filter { !self.magicMixPreviousKeys.contains($0.ratingKey) }
                let pool: [PlexMetadata]
                if fresh.count >= 50 {
                    pool = Array(fresh.shuffled().prefix(50))
                } else {
                    let repeats = allTracks.filter { self.magicMixPreviousKeys.contains($0.ratingKey) }
                    pool = Array((fresh + repeats).prefix(50))
                }
                return Self.albumDistributedShuffle(pool)
            }

            guard !selected.isEmpty else { return }

            await MainActor.run {
                self.magicMixPreviousKeys = Set(selected.map(\.ratingKey))
                for track in selected {
                    self.addToEndOfQueue(track)
                }
                self.logPlayback("magic_mix_refill_complete", "added=\(selected.count) upcoming=\(self.upcomingTracks.count)")
            }
        }
    }

    /// Shuffles tracks so songs from the same album are spread evenly across the result.
    /// Groups by album, shuffles within each group, then round-robins one track from each
    /// group per pass. With N albums of total M tracks, any two tracks from the same album
    /// are at least N positions apart.
    nonisolated static func albumDistributedShuffle(_ tracks: [PlexMetadata]) -> [PlexMetadata] {
        guard tracks.count > 1 else { return tracks }
        var byAlbum: [String: [PlexMetadata]] = [:]
        for track in tracks {
            let key = track.parentRatingKey ?? track.ratingKey
            byAlbum[key, default: []].append(track)
        }
        var groups = byAlbum.values.map { $0.shuffled() }
        var result: [PlexMetadata] = []
        result.reserveCapacity(tracks.count)
        while !groups.isEmpty {
            groups.shuffle()
            var nextGroups: [[PlexMetadata]] = []
            for var group in groups {
                result.append(group.removeFirst())
                if !group.isEmpty {
                    nextGroups.append(group)
                }
            }
            groups = nextGroups
        }
        return result
    }

    func requestMagicMixRefill(freshMix: Bool = false) {
        if freshMix {
            magicMixRefillTask?.cancel()
            magicMixRefillTask = nil
            magicMixPreviousKeys.removeAll()
        }
        maybeRefillMagicMixQueueIfNeeded(trigger: freshMix ? "user_request" : "queue_low")
    }

    func requestInfiniteRefill() {
        infiniteRefillTask?.cancel()
        infiniteRefillTask = nil
        maybeRefillInfiniteQueueIfNeeded(trigger: "user_request")
    }

    private func maybeRefillInfiniteQueueIfNeeded(trigger: String) {
        guard isInfiniteModeActive else { return }
        let needed = 5 - upcomingTracks.count
        guard needed > 0 else { return }
        guard infiniteRefillTask == nil else { return }
        guard let server, let client else { return }
        guard let sectionId = AppContext.shared.serverConnection?.currentLibrarySectionId else { return }

        logPlayback("infinite_refill_begin", "trigger=\(trigger) needed=\(needed)")

        infiniteRefillTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.infiniteRefillTask = nil
                }
            }

            guard let self else { return }
            let allTracks = (try? await client.cachedTracks(server: server, sectionId: sectionId)) ?? []

            guard !Task.isCancelled else { return }
            guard !allTracks.isEmpty else {
                await MainActor.run {
                    self.logPlayback("infinite_refill_empty", "trigger=\(trigger)")
                }
                return
            }

            let selected: [PlexMetadata] = await MainActor.run {
                let currentNeeded = 5 - self.upcomingTracks.count
                guard currentNeeded > 0 else { return [] }
                let fresh = allTracks.filter { !self.infinitePreviousKeys.contains($0.ratingKey) }
                let pool = fresh.isEmpty ? allTracks : fresh
                return Array(pool.shuffled().prefix(currentNeeded))
            }

            guard !selected.isEmpty else { return }

            await MainActor.run {
                for key in selected.map(\.ratingKey) {
                    self.infinitePreviousKeys.insert(key)
                }
                if self.infinitePreviousKeys.count > allTracks.count / 2 {
                    self.infinitePreviousKeys.removeAll()
                }
                for track in selected {
                    self.addToEndOfQueue(track)
                }
                self.logPlayback("infinite_refill_complete", "added=\(selected.count) upcoming=\(self.upcomingTracks.count)")
            }
        }
    }

    private func observeSoundCheckToggle() {
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
            }
        }
    }

    private func observeAudioRouteChanges() {
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

    private func observeAudioInterruptions() {
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let userInfo = notification.userInfo,
                  let raw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options: AVAudioSession.InterruptionOptions = {
                guard let raw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return [] }
                return AVAudioSession.InterruptionOptions(rawValue: raw)
            }()
            Task { @MainActor in
                self.handleAudioInterruption(type: type, options: options)
            }
        }
    }

    private func handleAudioInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            wasInterruptedWhilePlaying = isPlaying
            if isPlaying {
                isPlaying = false
                updateNowPlayingInfo()
            }
            logPlayback("audio_interruption_began", "was_playing=\(wasInterruptedWhilePlaying)")
        case .ended:
            let shouldResume = options.contains(.shouldResume) && wasInterruptedWhilePlaying
            logPlayback("audio_interruption_ended", "should_resume=\(shouldResume)")
            wasInterruptedWhilePlaying = false
            guard shouldResume else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                logPlayback("audio_session_reactivate_failed", "error=\(error.localizedDescription)")
                return
            }
            if let player, let item = player.currentItem, item.status != .failed {
                player.play()
                isPlaying = true
                updateNowPlayingInfo()
                reportTimelineState("playing")
            } else {
                recoverAndPlayCurrentTrackIfPossible(resumeAt: preferredResumeTimeForRecovery())
            }
        @unknown default:
            break
        }
    }

    private func observeNetworkChanges() {
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

    private func handleNetworkPathChange() {
        let newType = NetworkStatus.shared.interfaceType
        let newConnected = NetworkStatus.shared.isConnected
        let oldType = lastNetworkInterfaceType
        let oldConnected = lastNetworkIsConnected
        lastNetworkInterfaceType = newType
        lastNetworkIsConnected = newConnected

        let interfaceChanged = newType != oldType
        let lostConnection = oldConnected && !newConnected
        let reconnected = !oldConnected && newConnected
        guard interfaceChanged || reconnected || lostConnection else { return }
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

            await AppContext.shared.serverConnection?.reprobe()
            guard !Task.isCancelled, self.playbackGeneration == generation, self.isPlaying else { return }

            if let updatedServer = AppContext.shared.serverConnection?.currentServer {
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

    /// Buffer enough of the current track to make playback resilient to network changes.
    /// Caps at 30 minutes to avoid runaway memory on very long items.
    private func preferredFullTrackBufferDuration() -> TimeInterval {
        let known = duration
        let target = known > 0 ? known + 30 : 600
        return min(target, 1800)
    }

    // MARK: - Next Track Preload

    private func maybePreloadNextTrack() {
        guard duration > 0 else { return }
        let remaining = duration - currentTime
        guard remaining > 0, remaining <= 25 else { return }
        guard nextTrackPreloadTask == nil, preloadedNext == nil else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }

        let nextTrack: PlexMetadata?
        if repeatMode == .one {
            nextTrack = currentTrack
        } else if currentIndex < queue.count - 1 {
            nextTrack = queue[currentIndex + 1]
        } else if repeatMode == .all, !queue.isEmpty {
            nextTrack = queue[0]
        } else {
            nextTrack = nil
        }
        guard let track = nextTrack else { return }

        nextTrackPreloadTask = Task { [weak self] in
            await self?.performPreload(track)
        }
    }

    private func performPreload(_ track: PlexMetadata) async {
        defer { nextTrackPreloadTask = nil }
        guard let server, let client else { return }

        let playbackPath = resolvedPlaybackPath(for: server)
        let disableCellularTranscoding = UserDefaults.standard.bool(forKey: Self.disableCellularTranscodingKey)
        let cellularBitrate = Self.validatedCellularTranscodeBitrate(
            UserDefaults.standard.integer(forKey: Self.cellularTranscodeBitrateKbpsKey)
        )
        let shouldConstrain: Bool = switch playbackPath {
        case .cellular, .wan, .relay: !disableCellularTranscoding
        case .lan: false
        }

        let sessionID = UUID().uuidString
        let metadataPath = track.key ?? "/library/metadata/\(track.ratingKey)"
        let normalizedPath = metadataPath.hasPrefix("/") ? metadataPath : "/\(metadataPath)"
        let headers = client.playbackHeaders(
            server: server,
            sessionID: sessionID,
            preferAACTranscode: shouldConstrain,
            avoidAudioTranscode: !shouldConstrain
        )

        do {
            try await client.universalDecision(
                server: server,
                metadataPath: normalizedPath,
                sessionID: sessionID,
                headers: headers,
                location: playbackPath.locationQueryValue,
                constrainAudioBitrate: shouldConstrain,
                cellularTranscodeBitrate: cellularBitrate
            )
        } catch {
            logPlayback("preload_decision_failed", "error=\(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }

        let candidates = client.universalStreamURLCandidates(
            server: server,
            mediaPathCandidates: [normalizedPath],
            sessionID: sessionID,
            location: playbackPath.locationQueryValue,
            constrainAudioBitrate: shouldConstrain,
            cellularTranscodeBitrate: cellularBitrate
        )
        guard let streamURL = candidates.first else {
            logPlayback("preload_no_url")
            return
        }

        preloadedNext = PreloadedNextTrack(
            ratingKey: track.ratingKey,
            streamURL: streamURL,
            candidates: candidates,
            sessionID: sessionID,
            shouldConstrain: shouldConstrain
        )
        logPlayback("preload_complete", "track=\(track.ratingKey)")
    }

    private func consumePreloadedNextTrack(for ratingKey: String) -> PreloadedNextTrack? {
        guard let preloaded = preloadedNext else { return nil }
        guard preloaded.ratingKey == ratingKey else {
            discardPreloadedNext()
            return nil
        }
        preloadedNext = nil
        return preloaded
    }

    private func discardPreloadedNext() {
        nextTrackPreloadTask?.cancel()
        nextTrackPreloadTask = nil
        if let preloaded = preloadedNext, let server, let client {
            let sessionID = preloaded.sessionID
            Task.detached { await client.universalTranscodeStop(server: server, sessionID: sessionID) }
        }
        preloadedNext = nil
    }

    private func refreshAirPlayConnectionState() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        isAirPlayConnected = outputs.contains { $0.portType == .airPlay }
        isCarPlayConnected = outputs.contains { $0.portType == .carAudio }
    }

    /// Computes the AVPlayer volume (0.0–1.0) based on ReplayGain data.
    /// ReplayGain `gain` is the dB adjustment needed to reach −18 LUFS.
    /// We add +7 dB to target −11 LUFS instead, then clamp to AVPlayer's range.
    /// Uses detailed track metadata (fetched before playback) for stream-level gain values.
    private func soundCheckVolume(for track: PlexMetadata?) -> Float {
        guard UserDefaults.standard.bool(forKey: Self.soundCheckKey) else { return 1.0 }
        let source = detailedTrackForSoundCheck ?? track
        guard let stream = source?.media?.first?.part?.first?.stream?.first(where: { $0.streamType == 2 }) else {
            return 1.0
        }
        let gainSource = UserDefaults.standard.string(forKey: Self.soundCheckGainSourceKey) ?? SoundCheckGainSource.track.rawValue
        let selectedSource = SoundCheckGainSource(rawValue: gainSource) ?? .track
        let gainDB: Double
        switch selectedSource {
        case .track:
            gainDB = stream.gain ?? stream.albumGain ?? 0.0
        case .album:
            gainDB = stream.albumGain ?? stream.gain ?? 0.0
        }
        let adjustedDB = gainDB + 7.0
        let linear = Float(pow(10.0, adjustedDB / 20.0))
        return min(max(linear, 0.0), 1.0)
    }

    // MARK: - Observers

    /// Watches the player item's status. Once .readyToPlay fires, loads the
    /// authoritative duration from the parsed STREAMINFO / container header.
    private func observeItemStatus(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let assetDuration = observedItem.duration.seconds
            let errorDesc = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isReadyToPlay = true
                    if assetDuration.isFinite && assetDuration > 0 {
                        self.duration = assetDuration
                    }
                    self.logPlayback("item_ready", "duration=\(self.duration)")

                    if let pendingSeek = self.pendingInitialSeekTime {
                        self.pendingInitialSeekTime = nil
                        let safeUpper = self.duration > 1 ? max(self.duration - 1, 0) : self.duration
                        let bounded = safeUpper > 0 ? min(max(0, pendingSeek), safeUpper) : max(0, pendingSeek)
                        self.logPlayback("resume_seek", "to=\(bounded)")
                        self.isSeeking = true
                        let target = CMTime(seconds: bounded, preferredTimescale: 600)
                        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
                        self.player?.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                            guard let self else { return }
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.isSeeking = false
                                guard finished else { return }
                                self.currentTime = bounded
                                self.player?.play()
                                self.isPlaying = true
                                self.updateNowPlayingInfo()
                            }
                        }
                    }

                    self.updateNowPlayingInfo()
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

    private func observePlaybackFailures(_ item: AVPlayerItem) {
        let observedGeneration = playbackGeneration

        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
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
            forName: .AVPlayerItemFailedToPlayToEndTime,
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

    private func tearDownObservers() {
        removeTimeObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
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
    }

    // MARK: - Time Tracking

    private func addTimeObserver() {
        // 0.5 s strikes the balance between a smoothly-tracking slider and main-thread
        // wakeups. iOS computes lock-screen elapsed time from MPNowPlayingInfo's snapshot
        // + playback rate, so we only refresh that on track / state changes — not here.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let generation = playbackGeneration
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let self, self.playbackGeneration == generation else { return }
                guard !self.isSeeking else { return }
                guard seconds.isFinite && seconds >= 0 else { return }

                if let itemDuration = self.player?.currentItem?.duration.seconds,
                   itemDuration.isFinite && itemDuration > 0 {
                    self.duration = itemDuration
                }

                self.currentTime = self.duration > 0 ? min(seconds, self.duration) : seconds
                self.maybeReportScrobble()
                self.maybePreloadNextTrack()
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    // MARK: - Track End

    private func observePlayerState() {
        timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let status = observedPlayer.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                let waitingForPlayback = status == .waitingToPlayAtSpecifiedRate
                // Preserve the current "playing intent" while AVPlayer is briefly
                // buffering so transport controls do not flicker.
                let playing = status == .playing || (waitingForPlayback && self.isPlaying)
                #if DEBUG
                if self.lastLoggedTimeControlStatus != status {
                    self.lastLoggedTimeControlStatus = status
                    self.logPlayback("time_control", "status=\(status.rawValue)")
                }
                #endif
                self.isPlaying = playing
                self.updateNowPlayingInfo()
            }
        }
    }

    private func observeTrackEnd() {
        if let trackEndObserver {
            NotificationCenter.default.removeObserver(trackEndObserver)
            self.trackEndObserver = nil
        }
        if let item = player?.currentItem {
            trackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleTrackEnd()
                }
            }
        }
    }

    private func handleTrackEnd() {
        let hasNext = currentIndex < queue.count - 1 || repeatMode != .off
        maybeReportScrobble(force: true)
        logPlayback("track_end", "has_next=\(hasNext)")
        reportTimelineState("stopped", continuing: hasNext)
        next()
    }

    // MARK: - Timeline Reporting

    /// Best-effort lifecycle signal when the app is terminating.
    /// iOS may not deliver this on force-quit, but when it does we report stopped.
    func reportStoppedForAppTermination() {
        guard currentTrack != nil else { return }
        reportTimelineState("stopped", continuing: false)
        stopActiveTranscodeSession()
    }

    /// Fire-and-forget call to PMS to release the active transcode session.
    /// Without this, sessions accumulate on the server until its GC runs (~5 min),
    /// and Plex hits its concurrent-session limit after ~15 quick track advances.
    private func stopActiveTranscodeSession() {
        guard let sessionID = currentSessionID,
              let server,
              let client else { return }
        logPlayback("transcode_stop", "session=\(sessionID)")
        Task.detached { [client, server, sessionID] in
            await client.universalTranscodeStop(server: server, sessionID: sessionID)
        }
    }

    private func reportTimelineState(_ state: String, continuing: Bool = false) {
        guard let currentTrack, let client, let server else { return }
        let key = currentTrack.key ?? "/library/metadata/\(currentTrack.ratingKey)"
        let timeMs = Int(currentTime * 1000)
        let durationMs = Int(duration * 1000)
        let sessionID = currentSessionID
        Task {
            try? await client.reportTimeline(
                server: server,
                ratingKey: currentTrack.ratingKey,
                key: key,
                state: state,
                timeMs: timeMs,
                durationMs: durationMs,
                sessionID: sessionID,
                continuing: continuing
            )
        }
    }

    private func maybeReportScrobble(force: Bool = false) {
        guard let currentTrack, let client, let server else { return }
        guard scrobbledTrackRatingKey != currentTrack.ratingKey else { return }

        let shouldScrobble: Bool
        if force {
            shouldScrobble = true
        } else if duration > 0 {
            shouldScrobble = (currentTime / duration) >= scrobbleThreshold
        } else {
            shouldScrobble = false
        }

        guard shouldScrobble else { return }
        scrobbledTrackRatingKey = currentTrack.ratingKey
        logPlayback("scrobble", "time=\(Int(currentTime)) duration=\(Int(duration))")
        Task {
            try? await client.reportScrobble(server: server, ratingKey: currentTrack.ratingKey)
        }
    }

    // MARK: - State Persistence

    private static let trackKey = "playbackTrack"
    private static let queueKey = "playbackQueue"
    private static let originalQueueKey = "playbackOriginalQueue"
    private static let currentIndexKey = "playbackCurrentIndex"
    private static let soundCheckKey = "soundCheckEnabled"
    private static let soundCheckGainSourceKey = "soundCheckGainSource"
    private static let shuffleKey = "playbackShuffle"
    private static let repeatKey = "playbackRepeatMode"
    private static let disableCellularTranscodingKey = "disableCellularTranscoding"
    private static let cellularTranscodeBitrateKbpsKey = "cellularTranscodeBitrateKbps"
    private static let diagnosticsEnabledKey = "audioDiagnosticsEnabled"
    private static let supportedCellularTranscodeBitrates: Set<Int> = [192, 256, 320]

    private enum SoundCheckGainSource: String {
        case track
        case album
    }

    private static func validatedCellularTranscodeBitrate(_ bitrate: Int) -> Int {
        supportedCellularTranscodeBitrates.contains(bitrate) ? bitrate : 320
    }

    private func savePlaybackState() {
        let defaults = UserDefaults.standard
        if let track = currentTrack,
           let data = try? JSONEncoder().encode(track) {
            defaults.set(data, forKey: Self.trackKey)
        } else {
            defaults.removeObject(forKey: Self.trackKey)
        }
        if queue.isEmpty {
            defaults.removeObject(forKey: Self.queueKey)
        } else if let queueData = try? JSONEncoder().encode(queue) {
            defaults.set(queueData, forKey: Self.queueKey)
        }
        if originalQueue.isEmpty {
            defaults.removeObject(forKey: Self.originalQueueKey)
        } else if let origData = try? JSONEncoder().encode(originalQueue) {
            defaults.set(origData, forKey: Self.originalQueueKey)
        }
        defaults.set(currentIndex, forKey: Self.currentIndexKey)
        defaults.set(isShuffled, forKey: Self.shuffleKey)
        defaults.set(repeatMode.rawValue, forKey: Self.repeatKey)
    }

    func restorePlaybackState() {
        let defaults = UserDefaults.standard
        isShuffled = defaults.bool(forKey: Self.shuffleKey)
        if let raw = defaults.string(forKey: Self.repeatKey),
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        if let queueData = defaults.data(forKey: Self.queueKey),
           let savedQueue = try? JSONDecoder().decode([PlexMetadata].self, from: queueData) {
            queue = savedQueue
        }
        if let origData = defaults.data(forKey: Self.originalQueueKey),
           let savedOriginal = try? JSONDecoder().decode([PlexMetadata].self, from: origData) {
            originalQueue = savedOriginal
        }
        currentIndex = defaults.integer(forKey: Self.currentIndexKey)
        if currentIndex >= queue.count {
            currentIndex = 0
        }
        if let data = defaults.data(forKey: Self.trackKey),
           let track = try? JSONDecoder().decode(PlexMetadata.self, from: data) {
            currentTrack = track
            duration = Double(track.duration ?? 0) / 1000.0
        }
    }

    nonisolated private static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logPlayback("audio_session_setup_failed", "error=\(error.localizedDescription)")
        }
    }

    /// Pre-fetches detailed metadata (with gain values) for upcoming queue items
    /// so Sound Check doesn't need a network call at playback time.
    private func prefetchGainMetadata() {
        guard !isConstrainedPlaybackPath, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        guard UserDefaults.standard.bool(forKey: Self.soundCheckKey),
              let client, let server else { return }
        gainPrefetchTask?.cancel()
        // Prefetch current + next 10 tracks
        let upcoming = queue.dropFirst(currentIndex).prefix(11)
        let keys = upcoming.map(\.ratingKey)
        gainPrefetchTask = Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                let maxConcurrent = 3
                for key in keys {
                    guard !Task.isCancelled else { return }
                    if inFlight >= maxConcurrent {
                        await group.next()
                        inFlight -= 1
                    }
                    group.addTask {
                        _ = try? await client.cachedMetadata(server: server, ratingKey: key)
                    }
                    inFlight += 1
                }
                await group.waitForAll()
            }
        }
    }

    private func prefetchUpcomingArtwork() {
        guard !isConstrainedPlaybackPath, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        guard let client, let server else { return }
        let upcoming = queue.dropFirst(currentIndex + 1).prefix(5)
        let urls = upcoming.compactMap { track in
            let path = track.parentThumb ?? track.thumb
            return client.artworkURL(server: server, path: path, width: 300, height: 300)
        }
        Task { await ImageCache.shared.prefetch(urls: urls) }
    }

    // MARK: - Now Playing Info & Remote Commands

    private func setupRemoteCommands() {
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
            case .off: self.repeatMode = .off
            case .one: self.repeatMode = .one
            case .all: self.repeatMode = .all
            @unknown default: break
            }
            self.savePlaybackState()
            self.updateShuffleRepeatState()
            return .success
        }
        updateShuffleRepeatState()
    }

    private func updateShuffleRepeatState() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        switch repeatMode {
        case .off: center.changeRepeatModeCommand.currentRepeatType = .off
        case .all: center.changeRepeatModeCommand.currentRepeatType = .all
        case .one: center.changeRepeatModeCommand.currentRepeatType = .one
        }
    }

    private func resolvedPlaybackPath(for server: PlexServer) -> PlaybackPath {
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

    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTrack?.title ?? ""
        info[MPMediaItemPropertyArtist] = currentTrack?.artistDisplayName ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentTrack?.albumName ?? ""
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        let thumbPath = currentTrack?.thumb ?? currentTrack?.parentThumb

        if let cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if thumbPath != cachedArtworkThumbPath {
            cachedArtworkThumbPath = thumbPath
            cachedArtwork = nil
            nowPlayingArtworkTask?.cancel()
            if let client, let server,
               let url = client.artworkURL(server: server, path: thumbPath, width: 1000, height: 1000) {
                let generation = playbackGeneration
                let trackKey = currentTrack?.ratingKey
                nowPlayingArtworkTask = Task {
                    guard let image = await ImageCache.shared.image(for: url) else { return }
                    guard !Task.isCancelled else { return }
                    guard self.playbackGeneration == generation else { return }
                    guard self.currentTrack?.ratingKey == trackKey else { return }
                    let artwork = Self.makeArtwork(from: image)
                    self.cachedArtwork = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
                }
            }
        }
    }
}
