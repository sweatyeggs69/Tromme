import AVFoundation
import MediaPlayer
import Network
import Observation

extension AudioPlayerService {
    // MARK: - Time Tracking

    func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let generation = playbackGeneration
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let self, self.playbackGeneration == generation else { return }
                guard !self.isSeeking else { return }
                guard seconds.isFinite && seconds >= 0 else { return }
                if let preloaded = self.preloadedNext, self.player?.currentItem === preloaded.item { return }

                if self.isPlayingLocalFile {
                    self.currentTime = self.duration > 0 ? min(seconds, self.duration) : seconds
                } else {
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
                self.maybePlanAutoMix()
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
