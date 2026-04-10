import AVFoundation
import MediaPlayer
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

    enum RepeatMode: Sendable {
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
    private var playbackGeneration: Int = 0
    private var isSeeking = false
    private var server: PlexServer?
    private var client: PlexAPIClient?
    private var originalQueue: [PlexMetadata] = []

    /// Progress from 0 to 1
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var hasTrack: Bool { currentTrack != nil }

    init() {
        setupAudioSession()
        setupRemoteCommands()
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
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
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
        isSeeking = true
        currentTime = time
        nonisolated(unsafe) let weakSelf = self
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600)) { _ in
            weakSelf.isSeeking = false
        }
        updateNowPlayingInfo()
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
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
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

    /// Creates an AVPlayerItem with the full set of required Plex headers, including a
    /// per-session identifier. AVPlayer(url:) cannot send custom headers; AVURLAsset is
    /// required so that X-Plex-Token and X-Plex-Session-Identifier reach the server.
    private func makePlayerItem(url: URL, server: PlexServer) -> AVPlayerItem {
        let headers: [String: String] = [
            "X-Plex-Token": server.accessToken,
            "X-Plex-Client-Identifier": PlexAPIClient.clientIdentifier,
            "X-Plex-Product": PlexAPIClient.product,
            "X-Plex-Platform": PlexAPIClient.platform,
            "X-Plex-Version": PlexAPIClient.version,
            "X-Plex-Session-Identifier": UUID().uuidString,
        ]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    private func loadAndPlay(_ track: PlexMetadata) {
        currentTrack = track

        // Bump generation before removing the observer so any already-enqueued
        // callbacks from the previous track are ignored.
        playbackGeneration += 1
        currentTime = 0
        duration = Double(track.duration ?? 0) / 1000.0

        guard let server, let client,
              let partKey = track.media?.first?.part?.first?.key,
              let url = client.streamURL(server: server, partKey: partKey) else { return }

        removeTimeObserver()
        player = AVPlayer(playerItem: makePlayerItem(url: url, server: server))
        player?.play()
        isPlaying = true

        addTimeObserver()
        observeTrackEnd()
        updateNowPlayingInfo()
        prefetchUpcomingArtwork()
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

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Audio session setup failed
        }
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let generation = playbackGeneration
        nonisolated(unsafe) let weakSelf = self
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard weakSelf.playbackGeneration == generation, !weakSelf.isSeeking else { return }
            weakSelf.currentTime = min(time.seconds, weakSelf.duration)
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func observeTrackEnd() {
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        if let item = player?.currentItem {
            nonisolated(unsafe) let weakSelf = self
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                weakSelf.handleTrackEnd()
            }
        }
    }

    private func handleTrackEnd() {
        if let currentTrack, let client, let server {
            Task {
                try? await client.scrobble(server: server, ratingKey: currentTrack.ratingKey)
            }
        }
        next()
    }

    // MARK: - Now Playing Info & Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
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
