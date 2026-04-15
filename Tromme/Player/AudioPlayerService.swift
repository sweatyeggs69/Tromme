import AVFoundation
import MediaPlayer
import Network
import Observation

@Observable
final class AudioPlayerService {
    var currentTrack: PlexMetadata?
    var queue: [PlexMetadata] = []
    var currentIndex: Int = 0
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShuffled = false
    var repeatMode: RepeatMode = .off
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
    private var directFallbackURLForCurrentItem: URL?
    private var didFallbackToDirectForCurrentItem = false
    private var universalCandidatesForCurrentItem: [URL] = []
    private var universalCandidateIndexForCurrentItem = 0
    private var universalHeadersForCurrentItem: [String: String] = [:]
    private var currentSessionID: String?
    private let networkMonitor = NWPathMonitor()
    private var isCellular = false
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
        nonisolated(unsafe) let weakSelf = self
        networkMonitor.pathUpdateHandler = { path in
            weakSelf.isCellular = path.usesInterfaceType(.cellular)
        }
        networkMonitor.start(queue: .global(qos: .utility))
    }

    func configure(server: PlexServer, client: PlexAPIClient) {
        self.server = server
        self.client = client
    }

    // MARK: - Playback Control

    func play(tracks: [PlexMetadata], startingAt index: Int = 0) {
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
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            reportTimelineState("paused")
        } else {
            player.play()
            isPlaying = true
            reportTimelineState("playing")
        }
        updateNowPlayingInfo()
    }

    private func playCurrent() {
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
            currentTime = duration
            updateNowPlayingInfo()
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
        nonisolated(unsafe) let weakSelf = self
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
            DispatchQueue.main.async {
                weakSelf.isSeeking = false
                guard finished else { return }
                weakSelf.currentTime = boundedTime
                weakSelf.updateNowPlayingInfo()
                weakSelf.reportTimelineState(weakSelf.isPlaying ? "playing" : "paused")
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

    // MARK: - Private

    private func makePlayerItem(url: URL, headers: [String: String]? = nil) -> AVPlayerItem {
        guard let headers, !headers.isEmpty else {
            return AVPlayerItem(url: url)
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    private func loadAndPlay(_ track: PlexMetadata) {
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
        didFallbackToDirectForCurrentItem = false
        universalCandidatesForCurrentItem = []
        universalCandidateIndexForCurrentItem = 0
        universalHeadersForCurrentItem = [:]
        currentSessionID = UUID().uuidString

        guard let server, let client,
              let partKey = track.media?.first?.part?.first?.key,
              let directURL = client.streamURL(server: server, partKey: partKey) else { return }

        tearDownObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)

        if shouldUseUniversalHLS(for: track) {
            // Transcode via HLS for formats AVPlayer can't handle natively or reliably.
            let sessionID = currentSessionID!
            let metadataPath = track.key ?? "/library/metadata/\(track.ratingKey)"
            let normalizedPath = metadataPath.hasPrefix("/") ? metadataPath : "/\(metadataPath)"
            let mediaPathCandidates = [normalizedPath]
            let cellular = isCellular
            let headers = client.playbackHeaders(server: server, sessionID: sessionID, cellular: cellular)
            universalHeadersForCurrentItem = headers
            directFallbackURLForCurrentItem = directURL
            let generation = playbackGeneration
            let capturedClient = client
            let capturedServer = server

            nonisolated(unsafe) let weakSelf = self
            Task {
                // Step 1: Authorize the transcode session
                do {
                    try await capturedClient.universalDecision(
                        server: capturedServer,
                        metadataPath: normalizedPath,
                        sessionID: sessionID,
                        headers: headers,
                        cellular: cellular
                    )
                } catch {
                    guard weakSelf.playbackGeneration == generation else { return }
                    print("[AudioPlayer] Decision failed: \(error.localizedDescription). Using direct stream.")
                    weakSelf.startPlayback(url: directURL)
                    return
                }

                guard weakSelf.playbackGeneration == generation else { return }

                // Step 2: Fetch master playlist and resolve variant URL
                let universalCandidates = capturedClient.universalStreamURLCandidates(
                    server: capturedServer,
                    mediaPathCandidates: mediaPathCandidates,
                    sessionID: sessionID,
                    cellular: cellular
                )
                weakSelf.universalCandidatesForCurrentItem = universalCandidates

                guard let masterURL = universalCandidates.first else {
                    print("[AudioPlayer] Universal URL unavailable. Using direct stream.")
                    weakSelf.startPlayback(url: directURL)
                    return
                }

                do {
                    let variantURL = try await capturedClient.resolveVariantPlaylistURL(
                        masterURL: masterURL,
                        server: capturedServer,
                        headers: headers
                    )
                    guard weakSelf.playbackGeneration == generation else { return }
                    weakSelf.startPlayback(url: variantURL, headers: weakSelf.universalHeadersForCurrentItem)
                } catch {
                    guard weakSelf.playbackGeneration == generation else { return }
                    print("[AudioPlayer] Variant resolve failed: \(error.localizedDescription). Using direct stream.")
                    weakSelf.startPlayback(url: directURL)
                }
            }
        } else {
            directFallbackURLForCurrentItem = nil
            universalCandidatesForCurrentItem = []
            universalCandidateIndexForCurrentItem = 0
            universalHeadersForCurrentItem = [:]
            startPlayback(url: directURL)
        }
    }

    private func startPlayback(url: URL, headers: [String: String]? = nil) {
        let item = makePlayerItem(url: url, headers: headers)
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

    /// Formats that need the universal transcode path:
    /// - FLAC/WAV: AVPlayer plays them but seeking drifts out of sync over time
    /// - OGG/Opus/WMA/WavPack/Musepack: AVPlayer can't play these at all
    private static let universalTranscodeCodecs: Set<String> = [
        "flac", "wav", "ogg", "vorbis", "opus", "wma", "wmav2", "wavpack", "wv", "musepack", "mpc",
    ]
    private static let universalTranscodeContainers: Set<String> = [
        "flac", "wav", "ogg", "wma", "wv", "mpc",
    ]
    private static let universalTranscodeExtensions: Set<String> = [
        ".flac", ".wav", ".ogg", ".opus", ".wma", ".wv", ".mpc",
    ]

    private func shouldUseUniversalHLS(for track: PlexMetadata) -> Bool {
        track.media?.contains { media in
            let codec = media.audioCodec?.lowercased() ?? ""
            let container = media.container?.lowercased() ?? ""
            if Self.universalTranscodeCodecs.contains(codec) || Self.universalTranscodeContainers.contains(container) {
                return true
            }
            return media.part?.contains { part in
                let partContainer = part.container?.lowercased() ?? ""
                let filePath = part.file?.lowercased() ?? ""
                return Self.universalTranscodeContainers.contains(partContainer)
                    || Self.universalTranscodeExtensions.contains(where: { filePath.hasSuffix($0) })
            } ?? false
        } ?? false
    }


    // MARK: - Observers

    /// Watches the player item's status. Once .readyToPlay fires, loads the
    /// authoritative duration from the parsed STREAMINFO / container header.
    private func observeItemStatus(_ item: AVPlayerItem) {
        nonisolated(unsafe) let weakSelf = self
        statusObservation = item.observe(\.status, options: [.new]) { observedItem, _ in
            DispatchQueue.main.async {
                switch observedItem.status {
                case .readyToPlay:
                    weakSelf.isReadyToPlay = true
                    let assetDuration = observedItem.duration.seconds
                    if assetDuration.isFinite && assetDuration > 0 {
                        weakSelf.duration = assetDuration
                    }
                    weakSelf.updateNowPlayingInfo()
                case .failed:
                    weakSelf.isReadyToPlay = false
                    let nsError = observedItem.error as NSError?
                    print("[AudioPlayer] Item failed: \(observedItem.error?.localizedDescription ?? "unknown")")
                    let nextUniversalIndex = weakSelf.universalCandidateIndexForCurrentItem + 1
                    if weakSelf.universalCandidatesForCurrentItem.indices.contains(nextUniversalIndex) {
                        weakSelf.universalCandidateIndexForCurrentItem = nextUniversalIndex
                        let nextURL = weakSelf.universalCandidatesForCurrentItem[nextUniversalIndex]


                        weakSelf.startPlayback(url: nextURL, headers: weakSelf.universalHeadersForCurrentItem)
                        return
                    }
                    if !weakSelf.didFallbackToDirectForCurrentItem,
                       let fallbackURL = weakSelf.directFallbackURLForCurrentItem {
                        weakSelf.didFallbackToDirectForCurrentItem = true
                        weakSelf.directFallbackURLForCurrentItem = nil
                        weakSelf.universalHeadersForCurrentItem = [:]
                        print("[AudioPlayer] Universal stream failed. Using direct stream.")
                        weakSelf.startPlayback(url: fallbackURL)
                    }
                default:
                    break
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
                  let event = item.errorLog()?.events.last else { return }
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
        nonisolated(unsafe) let weakSelf = self
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard weakSelf.playbackGeneration == generation else {
                return
            }
            guard !weakSelf.isSeeking else { return }
            let seconds = time.seconds
            guard seconds.isFinite && seconds >= 0 else { return }

            // Keep duration in sync with the player item.
            if let itemDuration = weakSelf.player?.currentItem?.duration.seconds,
               itemDuration.isFinite && itemDuration > 0 {
                weakSelf.duration = itemDuration
            }

            weakSelf.currentTime = weakSelf.duration > 0 ? min(seconds, weakSelf.duration) : seconds

            if abs(weakSelf.currentTime - weakSelf.lastNowPlayingInfoSyncTime) >= 1 {
                weakSelf.lastNowPlayingInfoSyncTime = weakSelf.currentTime
                weakSelf.updateNowPlayingInfo()
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
        nonisolated(unsafe) let weakSelf = self
        timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { observedPlayer, _ in
            DispatchQueue.main.async {
                // Treat both .playing and .waitingToPlayAtSpecifiedRate as "playing"
                // to avoid UI flicker during buffering transitions.
                let playing = observedPlayer.timeControlStatus != .paused
                weakSelf.isPlaying = playing
                weakSelf.updateNowPlayingInfo()
            }
        }
    }

    private func observeTrackEnd() {
        if let trackEndObserver {
            NotificationCenter.default.removeObserver(trackEndObserver)
            self.trackEndObserver = nil
        }
        if let item = player?.currentItem {
            nonisolated(unsafe) let weakSelf = self
            trackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                weakSelf.handleTrackEnd()
            }
        }
    }

    private func handleTrackEnd() {
        let hasNext = currentIndex < queue.count - 1 || repeatMode != .off
        reportTimelineState("stopped", continuing: hasNext)
        if let currentTrack, let client, let server {
            Task {
                try? await client.scrobble(server: server, ratingKey: currentTrack.ratingKey)
            }
        }
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

    private static let lastTrackKey = "lastPlayingTrackRatingKey"
    private static let shuffleKey = "playbackShuffle"
    private static let repeatKey = "playbackRepeatMode"

    private func savePlaybackState() {
        let defaults = UserDefaults.standard
        defaults.set(currentTrack?.ratingKey, forKey: Self.lastTrackKey)
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
    }

    var lastPlayingTrackRatingKey: String? {
        UserDefaults.standard.string(forKey: Self.lastTrackKey)
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
            let path = track.thumb ?? track.parentThumb
            return client.artworkURL(server: server, path: path, width: 1000, height: 1000)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let client, let server {
            let thumbPath = currentTrack?.thumb ?? currentTrack?.parentThumb
            let url = client.artworkURL(server: server, path: thumbPath, width: 1000, height: 1000)
            if let url {
                Task {
                    guard let image = await ImageCache.shared.image(for: url) else { return }
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
                }
            }
        }
    }
}
