import AVFoundation
import MediaPlayer
import Network
import Observation

extension AudioPlayerService {
    // MARK: - Dynamic Downloads

    var isDynamicQueueDownloadEnabled: Bool {
        guard UserDefaults.standard.bool(forKey: Self.autoDownloadEnabledKey) else { return false }
        let mode = UserDefaults.standard.string(forKey: Self.autoDownloadModeKey)
            .flatMap(AutoDownloadMode.init(rawValue:)) ?? AutoDownloadMode.defaultMode
        return mode == .queue
    }

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
