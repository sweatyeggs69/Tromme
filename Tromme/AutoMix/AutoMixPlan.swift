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
    /// When the incoming song's lyrics come in before the overlap ends, it reaches full volume
    /// after this many seconds instead, and the outgoing outro tails off underneath it.
    var incomingFade: TimeInterval?

    enum FilterStyle: Sendable {
        case none
        /// The outgoing track thins out (high-pass) while the incoming opens up.
        case energetic
        /// The outgoing track darkens (low-pass) while the incoming fills in.
        case mellow
    }

    /// How far each song is through its fade (0...1) `elapsed` seconds into the mix.
    func progress(at elapsed: TimeInterval) -> (outgoing: Double, incoming: Double) {
        let outgoing = min(max(elapsed / overlap, 0), 1)
        guard let incomingFade, incomingFade < overlap else { return (outgoing, outgoing) }
        return (outgoing, min(max(elapsed / incomingFade, 0), 1))
    }

    /// Equal-power volumes for the given progress. With a short `incomingFade`, the outgoing
    /// song drops to half volume while the incoming one comes up, then tails out under it.
    func gains(_ progress: (outgoing: Double, incoming: Double)) -> (outgoing: Float, incoming: Float) {
        let incoming = Float(sin(progress.incoming * .pi / 2))
        guard let incomingFade, incomingFade < overlap else {
            return (Float(cos(progress.outgoing * .pi / 2)), incoming)
        }
        let split = incomingFade / overlap
        let outgoing = progress.outgoing < split
            ? cos(progress.outgoing / split * .pi / 3)
            : 0.5 * cos((progress.outgoing - split) / (1 - split) * .pi / 2)
        return (Float(outgoing), incoming)
    }

    /// Volume multipliers that move the louder song toward the quieter one's level across the
    /// overlap: a louder outgoing song eases down as it fades, a louder incoming song starts
    /// lower and reaches its own level by the end. Volume can't go above 1, so only cuts.
    func loudnessFactors(_ progress: (outgoing: Double, incoming: Double)) -> (outgoing: Float, incoming: Float) {
        guard let loudnessDifference else { return (1, 1) }
        let difference = min(max(loudnessDifference, -12), 12)
        return (Float(pow(10, min(0, difference) * progress.outgoing / 20)),
                Float(pow(10, min(0, -difference) * (1 - progress.incoming) / 20)))
    }

    func withOverlap(_ overlap: TimeInterval) -> AutoMixPlan {
        AutoMixPlan(outgoingKey: outgoingKey, incomingKey: incomingKey, startTime: startTime, overlap: overlap, introStart: introStart, filter: filter, isPlainCrossfade: isPlainCrossfade, loudnessDifference: loudnessDifference, incomingFade: incomingFade.map { min($0, overlap) })
    }
}
