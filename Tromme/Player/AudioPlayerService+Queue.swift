import AVFoundation
import MediaPlayer
import Network
import Observation

// Dynamic downloads and queue info.
extension AudioPlayerService {
    // MARK: - Dynamic Downloads

    var isDynamicQueueDownloadEnabled: Bool {
        guard UserDefaults.standard.bool(forKey: Self.autoDownloadEnabledKey) else { return false }
        let mode = UserDefaults.standard.string(forKey: Self.autoDownloadModeKey)
            .flatMap(AutoDownloadMode.init(rawValue:)) ?? AutoDownloadMode.defaultMode
        return mode == .queue
    }

    /// When Auto-Download is in Dynamic mode, downloads the current track plus
    /// upcoming queue tracks (capped at the configured limit) for offline
    /// playback. The queue can hold an entire library, so the cap keeps a
    /// rolling window that advances with playback rather than downloading
    /// everything at once.
    func syncDynamicQueueDownloads() {
        guard isDynamicQueueDownloadEnabled else { return }
        guard let server, let client,
              queue.indices.contains(currentIndex) else { return }
        let downloadManager = AppContext.shared.downloadManager
        let limit = Self.validatedDynamicDownloadLimit(
            UserDefaults.standard.integer(forKey: Self.dynamicDownloadLimitKey)
        )
        downloadManager.downloadBatch(
            tracks: Array(queue[currentIndex...].prefix(limit)),
            server: server,
            client: client
        )
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
        player?.removeAllItems()
        player = nil
        stopLosslessPlayback()
        tearDownObservers()
        // Turn off infinite mode before clearing the queue below — otherwise its
        // didSet-driven refill would fire on the now-empty queue mid-reset.
        // (cancelAllBackgroundTasks() above already cleared magicMixBuildTask.)
        isInfiniteModeActive = false
        queue = []
        originalQueue = []
        currentIndex = 0
        currentTrack = nil
        isPlaying = false
        playbackIntent = false
        lastPublishedNowPlayingTrackKey = nil
        currentTime = 0
        duration = 0
        magicMixSeedArtistKey = nil
        isReadyToPlay = false
        currentSessionID = nil
        pendingInitialSeekTime = nil
        streamTimeOffset = 0
        pendingStreamOffsetCalibration = false
        universalStreamURL = nil
        universalCandidatesForCurrentItem = []
        universalCandidateIndexForCurrentItem = 0
        detailedTrackForSoundCheck = nil
        cachedArtwork = nil
        cachedArtworkThumbPath = nil
        isConstrainedPlaybackPath = false
        isPlayingLocalFile = false
        localFileCodec = nil
        savePlaybackState()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
