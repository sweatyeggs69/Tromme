import AVFoundation
import MediaPlayer
import Network
import Observation

// Gapless next-track preloading.
extension AudioPlayerService {
    // MARK: - Next Track Preload

    /// The queue slot that plays when the current track ends on its own.
    func nextAutoAdvanceTarget() -> (index: Int, track: PlexMetadata)? {
        guard queue.indices.contains(currentIndex) else { return nil }
        if repeatMode != .off {
            return (currentIndex, queue[currentIndex])
        } else if currentIndex < queue.count - 1 {
            return (currentIndex + 1, queue[currentIndex + 1])
        }
        return nil
    }

    func maybePreloadNextTrack() {
        guard duration > 0 else { return }
        let remaining = duration - currentTime
        guard remaining > 0, remaining <= 25 else { return }
        guard nextTrackPreloadTask == nil, preloadedNext == nil else { return }
        guard player?.currentItem != nil else { return }
        guard let track = nextAutoAdvanceTarget()?.track else { return }

        nextTrackPreloadTask = Task { [weak self] in
            await self?.performPreload(track)
        }
    }

    /// Resolves the next track's URL using the same decision tree as loadAndPlay
    /// (local file → direct stream → HLS transcode) and enqueues a ready item.
    func performPreload(_ track: PlexMetadata) async {
        // A cancelled preload has already been cleared by discardPreloadedNext(),
        // and a replacement task may now own the slot.
        defer { if !Task.isCancelled { nextTrackPreloadTask = nil } }
        guard let server, let client else { return }

        let detailedTrack: PlexMetadata? = UserDefaults.standard.bool(forKey: Self.soundCheckKey)
            ? (try? await client.cachedMetadata(server: server, ratingKey: track.ratingKey))
            : nil
        guard !Task.isCancelled else { return }

        if let localURL = AppContext.shared.downloadManager.localURL(for: track.ratingKey) {
            let ext = localURL.pathExtension
            enqueuePreloaded(track, url: localURL, source: .local(codec: ext.isEmpty ? nil : ext.uppercased()), detailedTrack: detailedTrack)
            return
        }

        let playbackPath = resolvedPlaybackPath(for: server)
        let disableCellularTranscoding = UserDefaults.standard.bool(forKey: Self.disableCellularTranscodingKey)
        let cellularBitrate = Self.cellularTranscodeBitrateKbps
        let isConstrainedNetworkPath: Bool = switch playbackPath {
        case .cellular, .wan, .relay: !disableCellularTranscoding
        case .lan: false
        }
        let sourceExceedsTarget = sourceBitrate(for: track).map { $0 > cellularBitrate } ?? true
        let shouldConstrain = isConstrainedNetworkPath && sourceExceedsTarget

        if !shouldConstrain, sourceAudioCodec(for: track) != "flac",
           let partKey = track.media?.first?.part?.first?.key,
           let directURL = client.directStreamURL(server: server, partKey: partKey) {
            enqueuePreloaded(track, url: directURL, source: .direct, detailedTrack: detailedTrack)
            return
        }

        // Only the HLS path costs a PMS transcode session up front.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }

        let sessionID = UUID().uuidString
        let metadataPath = track.key ?? "/library/metadata/\(track.ratingKey)"
        let normalizedPath = metadataPath.hasPrefix("/") ? metadataPath : "/\(metadataPath)"
        let headers = client.playbackHeaders(
            server: server,
            sessionID: sessionID,
            preferAACTranscode: shouldConstrain,
            avoidAudioTranscode: !shouldConstrain,
            sourceCodec: sourceAudioCodec(for: track)
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
        guard let masterURL = candidates.first else {
            logPlayback("preload_no_url")
            return
        }
        let resolvedURL = await client.resolveUniversalVariantURL(masterURL: masterURL) ?? masterURL
        guard !Task.isCancelled else { return }

        enqueuePreloaded(
            track,
            url: resolvedURL,
            source: .hls(candidates: candidates, sessionID: sessionID, shouldConstrain: shouldConstrain),
            detailedTrack: detailedTrack
        )
    }

    func enqueuePreloaded(_ track: PlexMetadata, url: URL, source: PreloadedNextTrack.Source, detailedTrack: PlexMetadata?) {
        let item = makePlayerItem(url: url)
        if case .local = source {} else {
            item.preferredForwardBufferDuration = preferredFullTrackBufferDuration(for: Double(track.duration ?? 0) / 1000.0)
        }
        // The queue or player may have changed while the URL was resolving.
        guard let player, let currentItem = player.currentItem,
              nextAutoAdvanceTarget()?.track.ratingKey == track.ratingKey,
              player.canInsert(item, after: currentItem) else {
            logPlayback("preload_dropped", "track=\(track.ratingKey)")
            return
        }
        player.insert(item, after: currentItem)
        player.actionAtItemEnd = .advance
        preloadedNext = PreloadedNextTrack(
            ratingKey: track.ratingKey,
            streamURL: url,
            source: source,
            item: item,
            detailedTrack: detailedTrack
        )
        logPlayback("preload_complete", "track=\(track.ratingKey)")
    }

    /// Drops the enqueued item when it no longer matches what should play next
    /// (queue edits, repeat changes), or when a network change makes a
    /// streamed item's path/bitrate decision stale. The next time tick re-preloads.
    func revalidatePreloadedNext(networkChanged: Bool = false) {
        guard let preloaded = preloadedNext else { return }
        // Already advanced into it; handleTrackEnd will move state over.
        guard player?.currentItem !== preloaded.item else { return }
        let stillNext = nextAutoAdvanceTarget()?.track.ratingKey == preloaded.ratingKey
        let isLocal = if case .local = preloaded.source { true } else { false }
        guard !stillNext || (networkChanged && !isLocal) else { return }
        logPlayback("preload_invalidated", "track=\(preloaded.ratingKey) network=\(networkChanged)")
        discardPreloadedNext()
    }

    func consumePreloadedNextTrack(for ratingKey: String) -> PreloadedNextTrack? {
        guard let preloaded = preloadedNext else { return nil }
        guard preloaded.ratingKey == ratingKey else {
            discardPreloadedNext()
            return nil
        }
        preloadedNext = nil
        return preloaded
    }

    func discardPreloadedNext() {
        nextTrackPreloadTask?.cancel()
        nextTrackPreloadTask = nil
        if let preloaded = preloadedNext {
            if let player, player.currentItem !== preloaded.item {
                player.remove(preloaded.item)
            }
        }
        preloadedNext = nil
        player?.actionAtItemEnd = .none
    }

    func refreshAirPlayConnectionState() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let airPlayOutput = outputs.first { $0.portType == .airPlay }
        let carPlayOutput = outputs.first { $0.portType == .carAudio }
        isAirPlayConnected = airPlayOutput != nil
        isCarPlayConnected = carPlayOutput != nil
        activeRouteName = carPlayOutput?.portName ?? airPlayOutput?.portName
    }

    /// Computes the AVPlayer volume (0.0–1.0) based on ReplayGain data.
    /// ReplayGain `gain` is the dB adjustment needed to reach −18 LUFS.
    /// We add +2 dB to target −16 LUFS instead (Apple's own Sound Check reference),
    /// then clamp to AVPlayer's range. A smaller offset than −11 LUFS means loud
    /// tracks get attenuated less aggressively — larger attenuation exaggerates the
    /// equal-loudness (Fletcher-Munson) effect where bass sounds thinner at lower
    /// playback levels, even though the underlying signal's spectrum is unchanged.
    /// Uses detailed track metadata (fetched before playback) for stream-level gain values.
    func soundCheckVolume(for track: PlexMetadata?) -> Float {
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
        let adjustedDB = gainDB + 2.0
        let linear = Float(pow(10.0, adjustedDB / 20.0))
        return min(max(linear, 0.0), 1.0)
    }
}
