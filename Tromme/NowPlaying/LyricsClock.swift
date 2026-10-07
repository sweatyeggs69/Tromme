import Foundation

/// Playback time for lyrics. The player only publishes its time every half
/// second, which is too coarse for word timing and line switches, so the time
/// is extrapolated from the last report while playing.
struct LyricsClock: Equatable {
    var anchorTime: TimeInterval = 0
    var anchorDate: Date = .now
    var isPlaying = false
    /// How far lyrics run ahead of the audio, so they feel in sync.
    var advance: TimeInterval = 0

    /// Never extrapolate further than this past a report, so a stalled
    /// stream doesn't run the lyrics ahead of the audio.
    /// Lyrics run ahead of the audio by this much, since perfectly timed
    /// lyrics read as lagging.
    static let defaultAdvance: TimeInterval = 0.25

    private static let maxExtrapolation: TimeInterval = 1

    func time(at date: Date = .now) -> TimeInterval {
        guard isPlaying else { return anchorTime + advance }
        return anchorTime + advance + min(max(date.timeIntervalSince(anchorDate), 0), Self.maxExtrapolation)
    }
}
