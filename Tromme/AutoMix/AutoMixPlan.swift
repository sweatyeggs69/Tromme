import Foundation

struct AutoMixPlan: Sendable {
    let outgoingKey: String
    let incomingKey: String
    let startTime: TimeInterval
    let overlap: TimeInterval
    var introStart: TimeInterval?
    var filter: FilterStyle = .none
    var isPlainCrossfade = false
    var loudnessDifference: Double?
    var incomingFade: TimeInterval?

    enum FilterStyle: Sendable {
        case none
        case energetic
        case mellow
    }

    func progress(at elapsed: TimeInterval) -> (outgoing: Double, incoming: Double) {
        let outgoing = min(max(elapsed / overlap, 0), 1)
        guard let incomingFade, incomingFade < overlap else { return (outgoing, outgoing) }
        return (outgoing, min(max(elapsed / incomingFade, 0), 1))
    }

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
