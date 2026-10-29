import Foundation

/// Loudness and beat data for a slice of one track, held in memory only.
struct AutoMixWindowAnalysis: Sendable {
    /// Track time of the first level.
    let windowStart: TimeInterval
    /// Seconds per level.
    let frameDuration: TimeInterval
    /// RMS level of each frame in dBFS.
    let levels: [Float]
    let beat: BeatGrid?
    /// Beat measured only in the part used for the transition (the last or first seconds);
    /// nil when the drums drop out there, even if the rest of the window had a beat.
    let edgeBeat: BeatGrid?

    func time(ofFrame index: Int) -> TimeInterval {
        windowStart + Double(index) * frameDuration
    }
}
