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
    private var playbackGeneration: Int = 0
    private var lastNowPlayingInfoSyncTime: TimeInterval = 0
    private var server: PlexServer?
    private var client: PlexAPIClient?
    private var originalQueue: [PlexMetadata] = []
    private var universalCandidatesForCurrentItem: [URL] = []
    private var universalCandidateIndexForCurrentItem = 0
    private var currentSessionID: String?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkThumbPath: String?
    private var isCellular: Bool { NetworkStatus.shared.isCellular }
    private var isSeeking = false

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
    }

    func configure(server: PlexServer, client: PlexAPIClient) {
        self.server = server
        self.client = client
    }

    // MARK: - Playback Control

    func play(tracks: [PlexMetadata], startingAt index: Int = 0) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
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
        loadAndPlay(queue[currentIndex])
    }

    func togglePlayPause() {
        if player == nil, let track = currentTrack {
            if queue.isEmpty {
                queue = [track]
                currentIndex = 0
            }
            guard currentIndex < queue.count else { return }
            loadAndPlay(queue[currentIndex])
            return
        }
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
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
                reportTimelineState("playing")
                updateNowPlayingInfo()
                return
            }
            player.play()
            isPlaying = true
            reportTimelineState("playing")
        }
        updateNowPlayingInfo()
    }

    private func playCurrent() {
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

    func next() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one {
            loadAndPlay(queue[currentIndex])
            return
        }
        if currentIndex < queue.count - 1 {
            currentIndex += 1
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            player?.pause()
            isPlaying = false
            currentTime = 0
            player?.seek(to: .zero)
            updateNowPlayingInfo()
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
            print("[AudioPlayer] Seek blocked: not ready")
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
    }

    func addToEndOfQueue(_ track: PlexMetadata) {
        queue.append(track)
        originalQueue.append(track)
    }

    func removeFromQueue(at index: Int) {
        let queueIndex = currentIndex + 1 + index
        guard queueIndex < queue.count else { return }
        let track = queue.remove(at: queueIndex)
        if let origIndex = originalQueue.firstIndex(where: { $0.ratingKey == track.ratingKey }) {
            originalQueue.remove(at: origIndex)
        }
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
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        savePlaybackState()
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

    // MARK: - Private

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        AVPlayerItem(url: url)
    }

    private func loadAndPlay(_ track: PlexMetadata) {
        guard server != nil, client != nil else {
            print("[AudioPlayer] Cannot play: server/client not configured")
            return
        }

        // Report stopped for the previous track before switching
        if currentTrack != nil {
            reportTimelineState("stopped", continuing: true)
        }

        currentTrack = track
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

        Task {
            // Step 1: Authorize the transcode session.
            do {
                try await capturedClient.universalDecision(
                    server: capturedServer,
                    metadataPath: normalizedPath,
                    sessionID: sessionID,
                    headers: headers,
                    cellular: cellular,
                    disableCellularTranscoding: disableCellularTranscoding,
                    cellularTranscodeBitrate: cellularTranscodeBitrate
                )
            } catch {
                guard self.playbackGeneration == generation else { return }
                print("[AudioPlayer] Decision failed: \(error.localizedDescription)")
                self.isPlaying = false
                return
            }

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
                print("[AudioPlayer] Universal URL unavailable.")
                self.isPlaying = false
                return
            }
            guard self.playbackGeneration == generation else { return }
            self.startPlayback(url: masterURL)
        }
    }

    private func startPlayback(url: URL) {
        let item = makePlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()
        isPlaying = true

        observeItemStatus(item)
        observePlayerState()
        observeErrorLog(item)
        addTimeObserver()
        observeTrackEnd()
        updateNowPlayingInfo()
        prefetchUpcomingArtwork()
        reportTimelineState("playing")
        savePlaybackState()
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
                        self.updateNowPlayingInfo()
                    case .failed:
                        self.isReadyToPlay = false
                        print("[AudioPlayer] Item failed: \(errorDesc ?? "unknown")")
                        let nextIndex = self.universalCandidateIndexForCurrentItem + 1
                        if self.universalCandidatesForCurrentItem.indices.contains(nextIndex) {
                            self.universalCandidateIndexForCurrentItem = nextIndex
                            let nextURL = self.universalCandidatesForCurrentItem[nextIndex]
                            self.startPlayback(url: nextURL)
                            return
                        }
                        self.isPlaying = false
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
            let playing = observedPlayer.timeControlStatus != .paused
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
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
        reportTimelineState("stopped", continuing: hasNext)
        next()
    }

    // MARK: - Timeline Reporting

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

    // MARK: - State Persistence

    private static let trackKey = "playbackTrack"
    private static let shuffleKey = "playbackShuffle"
    private static let repeatKey = "playbackRepeatMode"
    private static let disableCellularTranscodingKey = "disableCellularTranscoding"
    private static let cellularTranscodeBitrateKbpsKey = "cellularTranscodeBitrateKbps"
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
    }

    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTrack?.title ?? ""
        info[MPMediaItemPropertyArtist] = currentTrack?.artistName ?? ""
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
