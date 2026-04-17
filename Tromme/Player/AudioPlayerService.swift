import AVFoundation
import MediaPlayer
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
    private var errorLogObserver: Any?
    private var trackEndObserver: Any?
    private var playbackStalledObserver: Any?
    private var itemFailedToEndObserver: Any?
    private var playbackGeneration: Int = 0
    private let maxRecoveryAttemptsPerTrack = 2
    private let scrobbleThreshold: Double = 0.9
    private var recoveryTrackRatingKey: String?
    private var recoveryAttemptsForTrack = 0
    private var lastNowPlayingInfoSyncTime: TimeInterval = 0
    private var server: PlexServer?
    private var client: PlexAPIClient?
    private var originalQueue: [PlexMetadata] = []
    private var universalCandidatesForCurrentItem: [URL] = []
    private var universalCandidateIndexForCurrentItem = 0
    private var currentSessionID: String?
    private var detailedTrackForSoundCheck: PlexMetadata?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkThumbPath: String?
    private var isCellular: Bool { NetworkStatus.shared.isCellular }
    private var isSeeking = false
    private var soundCheckObserver: NSObjectProtocol?
    private var lastLoggedTimeControlStatus: AVPlayer.TimeControlStatus?
    private var pendingInitialSeekTime: TimeInterval?
    private var scrobbledTrackRatingKey: String?

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
            // If the item has finished playing, seek to start before resuming
            if let item = player.currentItem,
               item.status == .readyToPlay,
               item.duration.seconds.isFinite,
               CMTimeGetSeconds(item.currentTime()) >= item.duration.seconds - 0.5 {
                currentTime = 0
                let currentPlayer = player
                currentPlayer.seek(to: .zero) { _ in
                    currentPlayer.play()
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
            currentPlayer.seek(to: .zero) { _ in
                currentPlayer.play()
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

    private func logPlayback(_ event: String, _ details: String = "") {
        guard diagnosticsEnabled else { return }
        let trackKey = currentTrack?.ratingKey ?? "none"
        let prefix = "[AudioPlayer][\(event)] track=\(trackKey) idx=\(currentIndex)/\(max(queue.count - 1, 0))"
        if details.isEmpty {
            print(prefix)
        } else {
            print("\(prefix) \(details)")
        }
    }

    private func recoverAndPlayCurrentTrackIfPossible(resumeAt: TimeInterval? = nil) {
        if queue.indices.contains(currentIndex) {
            if let resumeAt {
                logPlayback("recover_queue_track", "resume_at=\(resumeAt)")
            } else {
                logPlayback("recover_queue_track")
            }
            loadAndPlay(queue[currentIndex], resumeAt: resumeAt)
            return
        }
        if let track = currentTrack {
            if let resumeAt {
                logPlayback("recover_current_track_seed_queue", "resume_at=\(resumeAt)")
            } else {
                logPlayback("recover_current_track_seed_queue")
            }
            queue = [track]
            currentIndex = 0
            loadAndPlay(track, resumeAt: resumeAt)
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

        let resumeTime: TimeInterval?
        if currentTime.isFinite, currentTime > 2 {
            resumeTime = currentTime
        } else if let playerTime = player?.currentTime().seconds, playerTime.isFinite, playerTime > 2 {
            resumeTime = playerTime
        } else {
            resumeTime = nil
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
        guard isReadyToPlay, let player else {
            logPlayback("seek_blocked", "reason=not_ready")
            return
        }
        let boundedTime = max(0, duration > 0 ? min(time, duration) : time)
        isSeeking = true
        currentTime = boundedTime

        let target = CMTime(seconds: boundedTime, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSeeking = false
                    guard finished else { return }
                    self.currentTime = boundedTime
                    self.updateNowPlayingInfo()
                    self.reportTimelineState(self.isPlaying ? "playing" : "paused")
                }
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
        queue = Array(queue.prefix(currentIndex + 1))
        originalQueue = queue
    }

    func resetPlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        queue = []
        originalQueue = []
        currentIndex = 0
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isMagicMixActive = false
        isInfiniteModeActive = false
        savePlaybackState()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Private

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        AVPlayerItem(url: url)
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
        currentTime = 0
        duration = Double(track.duration ?? 0) / 1000.0
        lastNowPlayingInfoSyncTime = 0
        universalCandidatesForCurrentItem = []
        universalCandidateIndexForCurrentItem = 0
        currentSessionID = UUID().uuidString

        guard let server, let client else { return }

        tearDownObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)

        let disableCellularTranscoding = UserDefaults.standard.bool(forKey: Self.disableCellularTranscodingKey)
        let cellularTranscodeBitrate = Self.validatedCellularTranscodeBitrate(
            UserDefaults.standard.integer(forKey: Self.cellularTranscodeBitrateKbpsKey)
        )
        // Always route audio through Plex universal HLS for stable seek/duration behavior.
        let sessionID = currentSessionID!
        let metadataPath = track.key ?? "/library/metadata/\(track.ratingKey)"
        let normalizedPath = metadataPath.hasPrefix("/") ? metadataPath : "/\(metadataPath)"
        let mediaPathCandidates = [normalizedPath]
        let cellular = isCellular
        let headers = client.playbackHeaders(
            server: server,
            sessionID: sessionID,
            cellular: cellular,
            disableCellularTranscoding: disableCellularTranscoding
        )
        let generation = playbackGeneration
        let capturedClient = client
        let capturedServer = server

        let soundCheckEnabled = UserDefaults.standard.bool(forKey: Self.soundCheckKey)
        let ratingKey = track.ratingKey

        Task {
            // Step 1: Authorize transcode session and fetch detailed metadata (for gain) in parallel.
            async let decisionResult: Void = capturedClient.universalDecision(
                server: capturedServer,
                metadataPath: normalizedPath,
                sessionID: sessionID,
                headers: headers,
                cellular: cellular,
                disableCellularTranscoding: disableCellularTranscoding,
                cellularTranscodeBitrate: cellularTranscodeBitrate
            )
            async let detailedTrack: PlexMetadata? = soundCheckEnabled
                ? (try? await capturedClient.cachedMetadata(server: capturedServer, ratingKey: ratingKey))
                : nil

            do {
                try await decisionResult
            } catch {
                guard self.playbackGeneration == generation else { return }
                self.logPlayback("decision_failed", "error=\(error.localizedDescription)")
                self.handlePlaybackFailure("decision_failed")
                return
            }

            self.detailedTrackForSoundCheck = await detailedTrack

            guard self.playbackGeneration == generation else { return }

            // Step 2: Build universal HLS URL and play directly.
            let universalCandidates = capturedClient.universalStreamURLCandidates(
                server: capturedServer,
                mediaPathCandidates: mediaPathCandidates,
                sessionID: sessionID,
                cellular: cellular,
                disableCellularTranscoding: disableCellularTranscoding,
                cellularTranscodeBitrate: cellularTranscodeBitrate
            )
            self.universalCandidatesForCurrentItem = universalCandidates

            guard let masterURL = universalCandidates.first else {
                self.logPlayback("universal_url_unavailable")
                self.isPlaying = false
                return
            }
            guard self.playbackGeneration == generation else { return }
            self.logPlayback("load_ready", "candidate_count=\(universalCandidates.count)")
            self.startPlayback(url: masterURL)
        }
    }

    private func startPlayback(url: URL) {
        logPlayback("start_playback", "path=\(url.path)")
        let item = makePlayerItem(url: url)
        item.preferredForwardBufferDuration = 20
        player = AVPlayer(playerItem: item)
        player?.automaticallyWaitsToMinimizeStalling = true
        player?.volume = soundCheckVolume(for: currentTrack)
        player?.play()
        isPlaying = true

        observeItemStatus(item)
        observePlayerState()
        observeErrorLog(item)
        observePlaybackFailures(item)
        addTimeObserver()
        observeTrackEnd()
        updateNowPlayingInfo()
        prefetchGainMetadata()
        prefetchUpcomingArtwork()
        reportTimelineState("playing")
        savePlaybackState()
    }

    private func observeSoundCheckToggle() {
        soundCheckObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.player?.volume = self.soundCheckVolume(for: self.currentTrack)
            }
        }
    }

    /// Computes the AVPlayer volume (0.0–1.0) based on ReplayGain data.
    /// ReplayGain `gain` is the dB adjustment needed to reach −18 LUFS.
    /// We add +4 dB to target −14 LUFS instead, then clamp to AVPlayer's range.
    /// Uses detailed track metadata (fetched before playback) for stream-level gain values.
    private func soundCheckVolume(for track: PlexMetadata?) -> Float {
        guard UserDefaults.standard.bool(forKey: Self.soundCheckKey) else { return 1.0 }
        let source = detailedTrackForSoundCheck ?? track
        guard let stream = source?.media?.first?.part?.first?.stream?.first(where: { $0.streamType == 2 }) else {
            return 1.0
        }
        let gainDB = stream.gain ?? stream.albumGain ?? 0.0
        let adjustedDB = gainDB + 4.0
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
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
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
                            let target = CMTime(seconds: bounded, preferredTimescale: 600)
                            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
                            self.player?.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                                guard let self, finished else { return }
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
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
                        let nextIndex = self.universalCandidateIndexForCurrentItem + 1
                        if self.universalCandidatesForCurrentItem.indices.contains(nextIndex) {
                            self.universalCandidateIndexForCurrentItem = nextIndex
                            let nextURL = self.universalCandidatesForCurrentItem[nextIndex]
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
    }

    /// Listens for error-log entries the server may emit (e.g. seek failures
    /// on servers that don't support HTTP Range requests).
    private func observeErrorLog(_ item: AVPlayerItem) {
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  let _ = item.errorLog()?.events.last else { return }
            // Non-fatal HLS error log entries (e.g. bandwidth mismatch) — no action needed
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

                self.logPlayback("playback_stalled")
                self.player?.play()

                let stallStartTime = {
                    if let playerTime = self.player?.currentTime().seconds, playerTime.isFinite {
                        return playerTime
                    }
                    return self.currentTime
                }()

                try? await Task.sleep(for: .seconds(6))
                guard self.playbackGeneration == observedGeneration else { return }
                guard self.currentTrack?.ratingKey == self.recoveryTrackRatingKey else { return }

                let status = self.player?.timeControlStatus
                let waitingReason = self.player?.reasonForWaitingToPlay
                let waitingReasonRaw = waitingReason?.rawValue ?? "none"
                let checkTime = {
                    if let playerTime = self.player?.currentTime().seconds, playerTime.isFinite {
                        return playerTime
                    }
                    return self.currentTime
                }()
                let progressed = checkTime - stallStartTime

                self.logPlayback("stall_check", "status=\(status?.rawValue ?? -1) waiting_reason=\(waitingReasonRaw) progressed=\(progressed)")

                if status == .playing || progressed > 1 {
                    return
                }

                if status == .waitingToPlayAtSpecifiedRate, waitingReason == .toMinimizeStalls {
                    self.logPlayback("stall_grace", "reason=toMinimizeStalls")
                    try? await Task.sleep(for: .seconds(10))
                    guard self.playbackGeneration == observedGeneration else { return }
                    guard self.currentTrack?.ratingKey == self.recoveryTrackRatingKey else { return }

                    let recheckStatus = self.player?.timeControlStatus
                    let recheckReason = self.player?.reasonForWaitingToPlay?.rawValue ?? "none"
                    let recheckTime = {
                        if let playerTime = self.player?.currentTime().seconds, playerTime.isFinite {
                            return playerTime
                        }
                        return self.currentTime
                    }()
                    let recheckProgressed = recheckTime - stallStartTime
                    self.logPlayback("stall_recheck", "status=\(recheckStatus?.rawValue ?? -1) waiting_reason=\(recheckReason) progressed=\(recheckProgressed)")

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
        if let errorLogObserver {
            NotificationCenter.default.removeObserver(errorLogObserver)
        }
        errorLogObserver = nil
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
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let generation = playbackGeneration
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            DispatchQueue.main.async { [weak self] in
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

                    if abs(self.currentTime - self.lastNowPlayingInfoSyncTime) >= 1 {
                        self.lastNowPlayingInfoSyncTime = self.currentTime
                        self.updateNowPlayingInfo()
                    }
                }
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
            let playing = status != .paused
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.lastLoggedTimeControlStatus != status {
                        self.lastLoggedTimeControlStatus = status
                        self.logPlayback("time_control", "status=\(status.rawValue)")
                    }
                    self.isPlaying = playing
                    self.updateNowPlayingInfo()
                }
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
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.handleTrackEnd()
                    }
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
    private static let shuffleKey = "playbackShuffle"
    private static let repeatKey = "playbackRepeatMode"
    private static let disableCellularTranscodingKey = "disableCellularTranscoding"
    private static let cellularTranscodeBitrateKbpsKey = "cellularTranscodeBitrateKbps"
    private static let diagnosticsEnabledKey = "audioDiagnosticsEnabled"
    private static let supportedCellularTranscodeBitrates: Set<Int> = [192, 256, 320]

    private static func validatedCellularTranscodeBitrate(_ bitrate: Int) -> Int {
        supportedCellularTranscodeBitrates.contains(bitrate) ? bitrate : 320
    }

    private func savePlaybackState() {
        let defaults = UserDefaults.standard
        if let track = currentTrack,
           let data = try? JSONEncoder().encode(track) {
            defaults.set(data, forKey: Self.trackKey)
        }
        if let queueData = try? JSONEncoder().encode(queue) {
            defaults.set(queueData, forKey: Self.queueKey)
        }
        if let origData = try? JSONEncoder().encode(originalQueue) {
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
            // Audio session setup failed
        }
    }

    /// Pre-fetches detailed metadata (with gain values) for upcoming queue items
    /// so Sound Check doesn't need a network call at playback time.
    private func prefetchGainMetadata() {
        guard UserDefaults.standard.bool(forKey: Self.soundCheckKey),
              let client, let server else { return }
        // Prefetch current + next 10 tracks
        let upcoming = queue.dropFirst(currentIndex).prefix(11)
        let keys = upcoming.map(\.ratingKey)
        Task.detached(priority: .utility) {
            for key in keys {
                _ = try? await client.cachedMetadata(server: server, ratingKey: key)
            }
        }
    }

    private func prefetchUpcomingArtwork() {
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
            if let client, let server,
               let url = client.artworkURL(server: server, path: thumbPath, width: 1000, height: 1000) {
                Task {
                    guard let image = await ImageCache.shared.image(for: url) else { return }
                    let artwork = Self.makeArtwork(from: image)
                    self.cachedArtwork = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
                }
            }
        }
    }
}
