import AVFoundation
import MediaPlayer
import Network
import Observation

// Queue and playback state persistence.
extension AudioPlayerService {
    // MARK: - State Persistence

    static let trackKey = "playbackTrack"
    static let queueKey = "playbackQueue"
    static let originalQueueKey = "playbackOriginalQueue"
    static let currentIndexKey = "playbackCurrentIndex"
    static let currentTimeKey = "playbackCurrentTime"
    static let soundCheckKey = "soundCheckEnabled"
    static let soundCheckGainSourceKey = "soundCheckGainSource"
    static let shuffleKey = "playbackShuffle"
    static let repeatKey = "playbackRepeatMode"
    static let disableCellularTranscodingKey = "disableCellularTranscoding"
    /// Cellular transcode target is fixed — no longer a user-configurable
    /// setting. Transcoding only kicks in when the source exceeds this anyway
    /// (see sourceBitrate(for:) callers), so there's no lower-bitrate option
    /// to pick from in the first place.
    static let cellularTranscodeBitrateKbps = 320
    static let infiniteModeKey = "infiniteModeActive"
    static let diagnosticsEnabledKey = "audioDiagnosticsEnabled"
    static let autoDownloadEnabledKey = "autoDownloadEnabled"
    static let autoDownloadModeKey = "autoDownloadMode"
    static let dynamicDownloadLimitKey = "dynamicDownloadLimit"
    static let supportedDynamicDownloadLimits: Set<Int> = [5, 10, 20]

    /// Application Support, not Caches: iOS may purge Caches under storage pressure, which
    /// would leave a restored track with an empty queue.
    nonisolated static var stateDirectoryURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "TrommePlaybackState", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var queueFileURL: URL {
        stateDirectoryURL.appending(path: "playbackQueue.json")
    }
    nonisolated static var originalQueueFileURL: URL {
        stateDirectoryURL.appending(path: "playbackOriginalQueue.json")
    }
    /// Pre-migration location, read once as a fallback.
    nonisolated static var legacyQueueFileURL: URL {
        URL.cachesDirectory.appending(path: "playbackQueue.json")
    }
    nonisolated static var legacyOriginalQueueFileURL: URL {
        URL.cachesDirectory.appending(path: "playbackOriginalQueue.json")
    }

    enum SoundCheckGainSource: String {
        case track
        case album
    }

    static func validatedDynamicDownloadLimit(_ limit: Int) -> Int {
        supportedDynamicDownloadLimits.contains(limit) ? limit : 5
    }

    static func queueIdentityHash(_ items: [PlexMetadata]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.ratingKey)
        }
        return hasher.finalize()
    }

    func savePlaybackState() {
        let defaults = UserDefaults.standard

        if let track = currentTrack,
           let data = try? JSONEncoder().encode(track) {
            defaults.set(data, forKey: Self.trackKey)
        } else {
            defaults.removeObject(forKey: Self.trackKey)
        }

        defaults.set(currentIndex, forKey: Self.currentIndexKey)
        defaults.set(isShuffled, forKey: Self.shuffleKey)
        defaults.set(repeatMode.rawValue, forKey: Self.repeatKey)

        // Queue encoding can be large for full-library shuffles. Capture snapshots
        // here on the MainActor and encode them on a background thread to avoid
        // blocking the UI when the queue contains hundreds of tracks.
        let queueHash = Self.queueIdentityHash(queue)
        let origHash = Self.queueIdentityHash(originalQueue)
        guard queueHash != lastSavedQueueHash || origHash != lastSavedOriginalQueueHash else { return }

        let queueSnapshot = queue
        let origSnapshot = originalQueue
        let saveQueue = queueHash != lastSavedQueueHash
        let saveOrig = origHash != lastSavedOriginalQueueHash
        if saveQueue { lastSavedQueueHash = queueHash }
        if saveOrig { lastSavedOriginalQueueHash = origHash }

        Task.detached(priority: .utility) {
            if saveQueue {
                let url = Self.queueFileURL
                if queueSnapshot.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                } else if let data = try? JSONEncoder().encode(queueSnapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
            if saveOrig {
                let url = Self.originalQueueFileURL
                if origSnapshot.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                } else if let data = try? JSONEncoder().encode(origSnapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    func restorePlaybackState() {
        let defaults = UserDefaults.standard
        isShuffled = defaults.bool(forKey: Self.shuffleKey)
        if let raw = defaults.string(forKey: Self.repeatKey),
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        isInfiniteModeActive = defaults.bool(forKey: Self.infiniteModeKey)
        if let queueData = (try? Data(contentsOf: Self.queueFileURL)) ?? (try? Data(contentsOf: Self.legacyQueueFileURL)),
           let savedQueue = try? JSONDecoder().decode([PlexMetadata].self, from: queueData) {
            queue = savedQueue
        } else if let queueData = defaults.data(forKey: Self.queueKey),
                  let savedQueue = try? JSONDecoder().decode([PlexMetadata].self, from: queueData) {
            queue = savedQueue
            defaults.removeObject(forKey: Self.queueKey)
        }
        if let origData = (try? Data(contentsOf: Self.originalQueueFileURL)) ?? (try? Data(contentsOf: Self.legacyOriginalQueueFileURL)),
           let savedOriginal = try? JSONDecoder().decode([PlexMetadata].self, from: origData) {
            originalQueue = savedOriginal
        } else if let origData = defaults.data(forKey: Self.originalQueueKey),
                  let savedOriginal = try? JSONDecoder().decode([PlexMetadata].self, from: origData) {
            originalQueue = savedOriginal
            defaults.removeObject(forKey: Self.originalQueueKey)
        }
        currentIndex = defaults.integer(forKey: Self.currentIndexKey)
        if currentIndex >= queue.count {
            currentIndex = 0
        }
        if let data = defaults.data(forKey: Self.trackKey),
           let track = try? JSONDecoder().decode(PlexMetadata.self, from: data) {
            currentTrack = track
            duration = Double(track.duration ?? 0) / 1000.0
            // loadAndPlay() normally sets these when the track is actually loaded, but
            // restore happens before that — without this, Now Playing shows the resumed
            // track with no downloaded/codec badge until playback is (re)started.
            // Deferred to a Task: restorePlaybackState() runs inside AudioPlayerService's
            // own init, which AppContext.shared constructs — touching AppContext.shared
            // here directly would re-enter the singleton's initializer.
            let ratingKey = track.ratingKey
            Task { @MainActor [weak self] in
                guard let self, self.currentTrack?.ratingKey == ratingKey else { return }
                if AppContext.shared.downloadManager.localURL(for: ratingKey) != nil {
                    self.isPlayingLocalFile = true
                    self.localFileCodec = AppContext.shared.downloadManager.records[ratingKey]?
                        .codecLabel(source: self.currentTrack?.media?.first)
                }
            }
        }
        // The track is recalled but always from the start; clear any position
        // persisted by older builds.
        defaults.removeObject(forKey: Self.currentTimeKey)
        lastSavedQueueHash = Self.queueIdentityHash(queue)
        lastSavedOriginalQueueHash = Self.queueIdentityHash(originalQueue)
    }

    nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
