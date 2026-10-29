import Foundation

/// How one track hands over to the next: when the outgoing track starts to fade,
/// how long the overlap lasts, where the incoming track starts, and the filter sweep.
struct AutoMixPlan: Sendable {
    let outgoingKey: String
    let incomingKey: String
    /// Track time at which the outgoing track starts to fade out.
    let startTime: TimeInterval
    /// Overlap length in seconds of playback.
    let overlap: TimeInterval
    /// Track time the incoming track starts from, part-way into a long intro; nil keeps its normal start.
    var introStart: TimeInterval?
    /// Filter sweep across the overlap.
    var filter: FilterStyle = .none
    /// A plain crossfade from the genre rules rather than a lyric-timed mix; Now Playing
    /// doesn't show the mix effect for it.
    var isPlainCrossfade = false
    /// Outgoing minus incoming ReplayGain (dB) when Sound Check is off, so the overlap can
    /// blend their loudness instead of jumping; nil leaves levels alone.
    var loudnessDifference: Double?

    enum FilterStyle: Sendable {
        case none
        /// The outgoing track thins out (high-pass) while the incoming opens up.
        case energetic
        /// The outgoing track darkens (low-pass) while the incoming fills in.
        case mellow
    }

    /// Equal-power volumes of the outgoing and incoming song `progress` (0...1) into the mix.
    static func gains(_ progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(max(progress, 0), 1)
        return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
    }

    /// Volume multipliers that move the louder song toward the quieter one's level across the
    /// overlap: a louder outgoing song eases down as it fades, a louder incoming song starts
    /// lower and reaches its own level by the end. Volume can't go above 1, so only cuts.
    func loudnessFactors(_ progress: Double) -> (outgoing: Float, incoming: Float) {
        guard let loudnessDifference else { return (1, 1) }
        let difference = min(max(loudnessDifference, -12), 12)
        let p = min(max(progress, 0), 1)
        return (Float(pow(10, min(0, difference) * p / 20)), Float(pow(10, min(0, -difference) * (1 - p) / 20)))
    }

    func withOverlap(_ overlap: TimeInterval) -> AutoMixPlan {
        AutoMixPlan(outgoingKey: outgoingKey, incomingKey: incomingKey, startTime: startTime, overlap: overlap, introStart: introStart, filter: filter, isPlainCrossfade: isPlainCrossfade, loudnessDifference: loudnessDifference)
    }
}
