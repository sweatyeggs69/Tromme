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

    func withOverlap(_ overlap: TimeInterval) -> AutoMixPlan {
        AutoMixPlan(outgoingKey: outgoingKey, incomingKey: incomingKey, startTime: startTime, overlap: overlap, introStart: introStart, filter: filter)
    }
}
