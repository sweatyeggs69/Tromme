import AVFoundation

extension AudioPlayerService {
    static let trimFadeLength: TimeInterval = 0.5

    static func trimFadeGain(at position: TimeInterval, start: TimeInterval?, stop: TimeInterval?) -> Float {
        var gain = 1.0
        if let start, position >= start { gain = min(gain, (position - start) / trimFadeLength) }
        if let stop { gain = min(gain, (stop - position) / trimFadeLength) }
        return Float(min(max(gain, 0), 1))
    }

    func beginTrimFade(resumeAt: TimeInterval?) {
        trimFadeTask?.cancel()
        trimFadeTask = nil
        trimFadeGain = 1
        guard let track = currentTrack else { return }
        let markers = AppContext.shared.trackMarkers
        let start = markers.start(for: track.ratingKey).flatMap { $0 > 0 ? $0 : nil }
        let stop = markers.stop(for: track.ratingKey)
        guard start != nil || stop != nil else { return }

        trimFadeGain = Self.trimFadeGain(at: resumeAt ?? 0, start: start, stop: stop)
        let generation = playbackGeneration
        trimFadeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.playbackGeneration == generation else { return }
                var nap: TimeInterval = 0.25
                if self.isReadyToPlay || self.losslessPlayer != nil {
                    let position = self.pendingInitialSeekTime ?? self.bestKnownPlaybackSeconds
                    let gain = Self.trimFadeGain(at: position, start: start, stop: stop)
                    if gain != self.trimFadeGain {
                        self.trimFadeGain = gain
                        self.applyIncomingVolume()
                    }
                    if gain < 1 {
                        nap = 0.025
                    } else if let stop {
                        nap = min(max(stop - Self.trimFadeLength - position, 0.025), 0.25)
                    } else if let start, position >= start + Self.trimFadeLength {
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(Int(nap * 1000)))
            }
        }
    }
}
