import Foundation

/// Playback time for lyrics. The player only publishes its time every half
/// second, which is too coarse for word timing and line switches, so the time
/// is extrapolated from the last report while playing.
struct LyricsClock: Equatable {
    var anchorTime: TimeInterval = 0
    var anchorDate: Date = .now
    var isPlaying = false

    /// Never extrapolate further than this past a report, so a stalled
    /// stream doesn't run the lyrics ahead of the audio.
    private static let maxExtrapolation: TimeInterval = 1

    func time(at date: Date = .now) -> TimeInterval {
        guard isPlaying else { return anchorTime }
        return anchorTime + min(max(date.timeIntervalSince(anchorDate), 0), Self.maxExtrapolation)
    }
}
