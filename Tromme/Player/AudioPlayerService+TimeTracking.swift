import AVFoundation
import MediaPlayer
import Network
import Observation

// Periodic time observer.
extension AudioPlayerService {
    // MARK: - Time Tracking

    func addTimeObserver() {
        // 0.5 s strikes the balance between a smoothly-tracking slider and main-thread
        // wakeups. iOS computes lock-screen elapsed time from MPNowPlayingInfo's snapshot
        // + playback rate, so we only refresh that on track / state changes — not here.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let generation = playbackGeneration
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let self, self.playbackGeneration == generation else { return }
                guard !self.isSeeking else { return }
                guard seconds.isFinite && seconds >= 0 else { return }
                // Already playing the enqueued item; state moves over on the currentItem change.
                if let preloaded = self.preloadedNext, self.player?.currentItem === preloaded.item { return }

                if self.isPlayingLocalFile {
                    // Local files: map player time straight to currentTime — no HLS
                    // offset needed. Duration stays pinned to Plex metadata; reading
                    // it from the asset would pick up corrupt Xing/VBR headers.
                    self.currentTime = self.duration > 0 ? min(seconds, self.duration) : seconds
                } else {
                    // HLS streams: calibrate whether the playlist timeline is
                    // absolute (offset already embedded) or relative (needs adding).
                    if self.pendingStreamOffsetCalibration, self.streamTimeOffset > 0, seconds > 0.5 {
                        self.pendingStreamOffsetCalibration = false
                        if seconds >= self.streamTimeOffset * 0.5 {
                            self.logPlayback("stream_offset_absolute", "player_time=\(seconds) offset=\(self.streamTimeOffset)")
                            self.streamTimeOffset = 0
                        } else {
                            self.logPlayback("stream_offset_relative", "player_time=\(seconds) offset=\(self.streamTimeOffset)")
                        }
                    }
                    if self.streamTimeOffset == 0,
                       let itemDuration = self.player?.currentItem?.duration.seconds,
                       itemDuration.isFinite && itemDuration > 0 {
                        self.duration = itemDuration
                    }
                    let absoluteSeconds = self.streamTimeOffset + seconds
                    self.currentTime = self.duration > 0 ? min(absoluteSeconds, self.duration) : absoluteSeconds
                }

                self.maybePingTimeline()
                self.maybePreloadNextTrack()
            }
        }
    }

    func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
}
