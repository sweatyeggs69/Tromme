import Foundation

/// How one track hands over to the next: when the outgoing track starts to fade,
/// how long the overlap lasts, where the incoming track starts, and the tempos to
/// blend when the two beat grids could be matched.
struct AutoMixPlan: Sendable {
    let outgoingKey: String
    let incomingKey: String
    /// Track time at which the outgoing track starts to fade out.
    let startTime: TimeInterval
    /// Overlap length in seconds of playback.
    let overlap: TimeInterval
    /// Track time the incoming track starts from; nil keeps its normal start.
    let introStart: TimeInterval?
    /// Outgoing and incoming tempos (BPM) when beat matching applies.
    let tempo: Tempo?
    /// The incoming track fades in on its own, so it needs less help from the mix.
    var incomingFadesIn = false
    /// Filter sweep that suits the song's mood.
    var filter: FilterStyle = .none
    /// Shape of the volume crossfade.
    var curve: Curve = .equalPower

    enum Curve: Sendable, CaseIterable {
        /// Constant combined loudness.
        case equalPower
        /// Eases in and out, so the swap happens mostly in the middle.
        case smooth
        /// Both songs are loud together for longer.
        case overlapping

        /// Volumes of the outgoing and incoming song `progress` (0...1) into the mix.
        func gains(_ progress: Double) -> (outgoing: Float, incoming: Float) {
            let p = min(max(progress, 0), 1)
            switch self {
            case .equalPower:
                return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
            case .smooth:
                let eased = p * p * (3 - 2 * p)
                return (Float(cos(eased * .pi / 2)), Float(sin(eased * .pi / 2)))
            case .overlapping:
                return (Float(cos(pow(p, 1.8) * .pi / 2)), Float(sin(pow(p, 0.6) * .pi / 2)))
            }
        }
    }

    enum FilterStyle: Sendable {
        case none
        /// Driving songs: the outgoing track thins out (high-pass) while the incoming opens up.
        case energetic
        /// Calm songs: the outgoing track darkens (low-pass) while the incoming fills in.
        case mellow
    }

    struct Tempo: Sendable {
        let outgoing: Double
        let incoming: Double

        /// Shared tempo `progress` (0...1) of the way through the overlap.
        func blended(at progress: Double) -> Double {
            outgoing + (incoming - outgoing) * progress
        }
    }

    func withOverlap(_ overlap: TimeInterval) -> AutoMixPlan {
        AutoMixPlan(
            outgoingKey: outgoingKey, incomingKey: incomingKey, startTime: startTime, overlap: overlap,
            introStart: introStart, tempo: tempo, incomingFadesIn: incomingFadesIn, filter: filter, curve: curve
        )
    }

    func withoutTempo() -> AutoMixPlan {
        AutoMixPlan(
            outgoingKey: outgoingKey, incomingKey: incomingKey, startTime: startTime, overlap: overlap,
            introStart: introStart, tempo: nil, incomingFadesIn: incomingFadesIn, filter: filter, curve: curve
        )
    }

    var isBeatMatched: Bool { tempo != nil }

    /// Incoming track media seconds played after `elapsed` seconds of overlap.
    func incomingMediaElapsed(_ elapsed: TimeInterval) -> TimeInterval {
        guard let tempo else { return elapsed }
        let s = min(elapsed, overlap)
        let area = tempo.outgoing * s + (tempo.incoming - tempo.outgoing) * s * s / (2 * overlap)
        return area / tempo.incoming + max(0, elapsed - overlap)
    }
}
