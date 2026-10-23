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
    /// Magic Mix isn't a toggle — it's a one-shot action you can press repeatedly to
    /// regenerate the mix. True only while a mix is actively being built.
    var isMagicMixActive: Bool { magicMixBuildTask != nil }
    /// Agnostic fallback: whenever the queue runs empty, top it off with a random
    /// track. Independent of Magic Mix — neither mode forces the other off.
    var isInfiniteModeActive = false {
        didSet {
            UserDefaults.standard.set(isInfiniteModeActive, forKey: Self.infiniteModeKey)
            maybeRefillInfiniteQueueIfNeeded(trigger: "infinite_mode_toggled")
        }
    }
    /// True once the current item's status is .readyToPlay.
    var isReadyToPlay = false
    /// True when the active audio output route is AirPlay.
    var isAirPlayConnected = false
    /// True when the active audio output route is CarPlay.
    var isCarPlayConnected = false
    /// Display name of the active AirPlay or CarPlay route, if any.
    var activeRouteName: String?

    enum RepeatMode: String, Sendable {
        /// `song` loops the current song until turned off; `once` replays it one
        /// more time, then switches itself off and the queue carries on.
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
    /// True when the current item is a direct stream (no PMS transcode/remux).
    /// On failure, this lets handlePlaybackFailure fall back to the HLS
    /// transcode path once instead of retrying the same direct URL twice more.
    var isDirectStreamAttempt = false
    var pendingInitialSeekTime: TimeInterval?
    /// When a streamed transcode session is started at a seek point, AVPlayer's
    /// timeline begins at 0 but actually represents this many seconds into the track.
    var streamTimeOffset: TimeInterval = 0
    /// PMS offset playlists sometimes report an absolute timeline (the media
    /// sequence already carries the offset). Until the first real time-observer
    /// tick we don't know which variant we got, so the offset math is verified
    /// once against the observed player time and dropped if it would double-count.
    var pendingStreamOffsetCalibration = false
    var heldSeekTask: Task<Void, Never>?
    var heldSeekTargetTime: TimeInterval = 0
    var lastSavedQueueHash: Int?
    var lastSavedOriginalQueueHash: Int?
    /// Last time a timeline update went to the server; drives the periodic timeline report.
    var lastTimelineReport: Date = .distantPast

    /// Infinite Mode continuously appends fresh tracks but nothing ever removed the
    /// played ones, so a long listening session grew `queue` without bound. Keep a
    /// bounded history behind the current track (enough for `previous()` to still work)
    /// and drop anything older.
    let infiniteModeHistoryLimit = 40
    /// Infinite Mode candidates: tracks from albums sharing a genre with the current
    /// track's album, at least one style and at least one mood (when the seed has them),
    /// weighted so tracks with more shared styles and moods come up more often. If that
    /// finds nothing it relaxes mood, then style, but keeps the genre; only when the
    /// current album has no genre at all (album or artist) does it use the whole library.
    var gainPrefetchTask: Task<Void, Never>?
    var playbackLoadTask: Task<Void, Never>?
    var nowPlayingArtworkTask: Task<Void, Never>?
    var magicMixBuildTask: Task<Void, Never>?
    var magicMixSeedArtistKey: String? = nil
    var infiniteRefillTask: Task<Void, Never>?
    var preloadedNext: PreloadedNextTrack?
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
        /// Pre-built item enqueued behind the current item for gapless advance.
        let item: AVPlayerItem
        let detailedTrack: PlexMetadata?

        var hlsSessionID: String? {
            if case .hls(_, let sessionID, _) = source { return sessionID }
            return nil
        }
    }

    /// Progress from 0 to 1
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var hasTrack: Bool { currentTrack != nil }

    /// True when the current track is being transcoded rather than direct-streamed.
    var isTranscoding: Bool { isConstrainedPlaybackPath }

    /// True when the current track is playing from a locally downloaded file.
    var isPlayingLocalDownload: Bool { isPlayingLocalFile }

    /// The source file bitrate in kbps, or nil when no track is loaded.
    var activeStreamBitrate: Int? {
        guard hasTrack else { return nil }
        let media = currentTrack?.media?.first
        let audioStream = media?.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })
        return audioStream?.bitrate ?? media?.bitrate
    }

    /// The codec currently being delivered to the audio pipeline.
    /// Returns "AAC" for constrained (cellular) transcodes, "ALAC" for FLAC files
    /// routed through the lossless HLS transcode, or the uppercased source codec otherwise.
    /// Returns nil when no track is loaded.
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

    /// The source file's raw audio codec (lowercased), used to pick a transcode
    /// profile that preserves already-compatible codecs instead of forcing ALAC.
    func sourceAudioCodec(for track: PlexMetadata) -> String? {
        let media = track.media?.first
        let audioStream = media?.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })
        return (audioStream?.codec ?? media?.audioCodec)?.lowercased()
    }

    /// The source file's bitrate in kbps, used to decide whether cellular
    /// transcoding is actually needed — no point re-encoding a file that's
    /// already at or under the cellular target bitrate.
    func sourceBitrate(for track: PlexMetadata) -> Int? {
        let media = track.media?.first
        let audioStream = media?.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })
        return audioStream?.bitrate ?? media?.bitrate
    }

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

    /// Updates the current track's userRating and syncs the lock screen heart in one call.
    /// Call this from any UI that can rate the currently playing track.
    func updateCurrentTrackRating(_ userRating: Double?) {
        currentTrack?.userRating = userRating
        setLikeCommandActive((userRating ?? 0) >= 10)
    }

    /// Persists a favorite/unfavorite rating for `track`, invalidating the favorites caches,
    /// posting `.favoritesDidChange`, and syncing the lock-screen heart if `track` is the
    /// currently playing track. Returns `true` on success; callers own their own optimistic
    /// UI state and should roll it back on `false`.
    @discardableResult
    func setFavorited(_ isFavorited: Bool, for track: PlexMetadata, server: PlexServer, client: PlexAPIClient, sectionId: String?) async -> Bool {
        let isCurrentTrack = track.ratingKey == currentTrack?.ratingKey
        if isCurrentTrack { updateCurrentTrackRating(isFavorited ? 10 : 0) }
        do {
            try await client.rateItem(server: server, ratingKey: track.ratingKey, rating: isFavorited ? 10 : -1)
            // Write the new rating into the local library before announcing the change.
            await client.refreshItem(server: server, ratingKey: track.ratingKey)
            NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            return true
        } catch {
            if isCurrentTrack { updateCurrentTrackRating(isFavorited ? 0 : 10) }
            return false
        }
    }

    /// Swaps in a track that was edited on the server so the queue, Now Playing and the lock
    /// screen show the new title, artist and album.
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

            // If the item has finished playing, seek to start before resuming
            if let item = player.currentItem,
               item.status == .readyToPlay,
               item.duration.seconds.isFinite,
               CMTimeGetSeconds(item.currentTime()) >= item.duration.seconds - 0.5 {
                // An offset stream's position 0 is mid-track; restart from the real start.
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
        if player == nil || player?.currentItem == nil || player?.currentItem?.status == .failed {
            recoverAndPlayCurrentTrackIfPossible()
            return
        }

        // If the player item has ended (song finished), re-seek to start before playing
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
        if let playerTime = player?.currentTime().seconds, playerTime.isFinite {
            return streamTimeOffset + playerTime
        }
        return currentTime
    }

    /// True when nothing is streaming, the file is local, or at least 30 s of the track is
    /// buffered ahead of the playhead (or all of it, for short tracks), so animated
    /// artwork can load without competing with the audio.
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

        // Direct stream failed — fall back to PMS's HLS transcode path once,
        // rather than retrying the same direct URL twice more. Doesn't consume
        // the normal retry budget below, so HLS gets its own fresh attempts.
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
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if currentIndex > 0 {
            currentIndex -= 1
        }
        loadAndPlay(queue[currentIndex])
    }

    /// Natural end-of-track (non-gapless path): repeat modes replay the song,
    /// otherwise move on through the queue.
    func advanceAfterTrackEnd() {
        if repeatMode != .off, queue.indices.contains(currentIndex) {
            consumeRepeatOnce()
            logPlayback("track_end_repeat", "mode=\(repeatMode.rawValue)")
            loadAndPlay(queue[currentIndex])
            return
        }
        next()
    }

    /// Repeat Once is spent the moment its replay starts.
    func consumeRepeatOnce() {
        guard repeatMode == .once else { return }
        repeatMode = .off
        savePlaybackState()
        updateShuffleRepeatState()
    }

    func seek(to time: TimeInterval) {
        let boundedTime = max(0, duration > 0 ? min(time, duration) : time)

        // Plex's live HLS transcode can't handle in-stream seeks — AVPlayer stalls
        // waiting for segments the transcoder hasn't produced yet. Restart the
        // transcode session with an offset so PMS begins transcoding at the seek
        // point. Locally downloaded files and direct streams (plain byte-range-
        // served files, no live transcode) seek in place instead — restarting
        // those tears down and rebuilds the whole AVPlayer on every drag tick.
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

        // 50ms tolerance: precise enough to be imperceptible, but avoids the
        // finished=false failures that zero-tolerance seeks produce on VBR files
        // (when no sample exists at the exact requested time). Zero tolerance
        // caused the player to not move while currentTime was already updated,
        // producing visible slider jumps when the time observer fired.
        let target = CMTime(seconds: boundedTime, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
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
        playbackLoadTask = nil
        nowPlayingArtworkTask = nil
        gainPrefetchTask = nil
        magicMixBuildTask = nil
        infiniteRefillTask = nil
        networkRecoveryTask = nil
        nextTrackPreloadTask = nil
        heldSeekTask = nil
    }

    func makePlayerItem(url: URL) -> AVPlayerItem {
        AVPlayerItem(url: url)
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

    func loadAndPlay(_ track: PlexMetadata, resumeAt: TimeInterval? = nil, forceHLS: Bool = false) {
        guard server != nil, client != nil else {
            logPlayback("load_failed", "reason=server_or_client_not_configured requested=\(track.ratingKey)")
            return
        }

        pendingInitialSeekTime = nil
        streamTimeOffset = 0
        pendingStreamOffsetCalibration = false
        if let resumeAt {
            logPlayback("load_begin", "requested=\(track.ratingKey) queue_count=\(queue.count) resume_at=\(resumeAt)")
        } else {
            logPlayback("load_begin", "requested=\(track.ratingKey) queue_count=\(queue.count)")
        }

        // Report stopped for the previous track before switching
        if currentTrack != nil {
            reportTimelineState("stopped", continuing: true)
        }
        // Repeat Once belongs to the song it was set on; moving to another song cancels it.
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
        if let outgoing = player, playbackIntent, outgoing.timeControlStatus == .playing {
            // Keep the outgoing player running, muted, until the new item takes over.
            // Pausing it now leaves nothing playing while the stream is set up, and
            // CarPlay flashes paused on every skip. startPlayback() stops it.
            outgoing.volume = 0
        } else {
            player?.pause()
            player?.removeAllItems()
        }

        // Fast path: locally downloaded file — skip network transcode entirely.
        // Plex metadata duration is authoritative for local files: downloaded MP3
        // transcodes can have corrupt Xing/VBR headers that AVFoundation would
        // read as a wrong duration. duration is already set from track.duration above.
        if let localURL = AppContext.shared.downloadManager.localURL(for: track.ratingKey) {
            discardPreloadedNext()
            logPlayback("load_local_file", "track=\(track.ratingKey)")
            isPlayingLocalFile = true
            let ext = localURL.pathExtension
            localFileCodec = ext.isEmpty ? nil : ext.uppercased()
            currentSessionID = nil
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
        // Only actually transcode down when the source exceeds the target
        // bitrate — unknown bitrate is treated as "might exceed it" so we
        // stay conservative rather than risk uncapped cellular usage.
        let sourceExceedsTarget = sourceBitrate(for: track).map { $0 > cellularTranscodeBitrate } ?? true
        let shouldConstrainForNetwork = isConstrainedNetworkPath && sourceExceedsTarget

        // Direct stream for non-FLAC content — bypasses PMS's HLS transcode/remux
        // entirely. That remux path is fragile against source files with
        // malformed VBR/Xing headers (this library has some), which produces
        // outright playback failures rather than just an imprecise duration.
        // FLAC (needs lossless ALAC) and cellular-bitrate-constrained playback
        // still require PMS's transcode, so they fall through to HLS below.
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

        // A preloaded session always starts at 0, so it can't serve a mid-track resume.
        if boundedResume != nil {
            discardPreloadedNext()
        }

        // Fast path: use preloaded next track URL/session if it matches.
        // Saves the universalDecision API round-trip on track transitions.
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

        // FLAC or cellular-constrained: route through Plex universal HLS.
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

        // Start the transcode at the resume point rather than seeking after the
        // fact — PMS otherwise has to transcode everything up to the target first.
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
            // Step 1: Authorize transcode session and fetch detailed metadata (for gain) in parallel.
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

            // Step 2: Build universal HLS URL and play directly.
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
        let item = makePlayerItem(url: url)
        // Network streams need a buffer headroom hint and stall-minimization;
        // local files are already on disk so neither applies.
        if !isPlayingLocalFile {
            item.preferredForwardBufferDuration = preferredFullTrackBufferDuration(for: duration)
        }
        player?.pause()
        player?.removeAllItems()
        let queuePlayer = AVQueuePlayer(playerItem: item)
        // Only advance on item end while a gapless next item is enqueued; otherwise
        // keep the finished item. .none (not .pause) leaves the player in the playing
        // state through the gap before the next track loads, so CarPlay never shows
        // paused (and the audio session isn't released) between songs.
        queuePlayer.actionAtItemEnd = .none
        player = queuePlayer
        // Local files are on disk — stall minimization only applies to network streams.
        player?.automaticallyWaitsToMinimizeStalling = !isPlayingLocalFile
        player?.volume = soundCheckVolume(for: currentTrack)

        // Local files with a pending seek must not play from position 0 — the
        // readyToPlay handler will start playback after the seek completes.
        // Streams always play immediately because the offset is baked into the URL.
        // Either way, a reload triggered by seeking while paused (e.g. an HLS
        // seek-restart) must not resume playback the user didn't ask for.
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

    /// Buffer enough of the current track to make playback resilient to network changes.
    /// Caps at 30 minutes to avoid runaway memory on very long items.
    func preferredFullTrackBufferDuration(for known: TimeInterval) -> TimeInterval {
        let target = known > 0 ? known + 30 : 600
        return min(target, 1800)
    }

}
