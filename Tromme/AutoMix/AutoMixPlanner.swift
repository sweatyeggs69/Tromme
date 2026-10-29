import Foundation

/// Chooses where and how a track hands over to the next from their analyses.
enum AutoMixPlanner {
    private static let silenceFloor: Float = -50
    private static let defaultOverlap: TimeInterval = 5
    private static let maximumTempoShift = 0.08

    /// - Parameters:
    ///   - outgoingEnd: Track time where the outgoing track stops (duration or stop marker).
    ///   - incomingBaseStart: The incoming track's start marker, or 0.
    ///   - isContinuousAlbum: The next track follows this one on the same album.
    /// - Returns: nil when the tracks should simply play gapless.
    static func plan(
        outgoingKey: String,
        incomingKey: String,
        outgoingEnd: TimeInterval,
        incomingBaseStart: TimeInterval,
        outgoing: AutoMixWindowAnalysis?,
        incoming: AutoMixWindowAnalysis?,
        isContinuousAlbum: Bool
    ) -> AutoMixPlan? {
        var audibleEnd = outgoingEnd
        var fadeStart: TimeInterval?
        if let outgoing {
            let measured = tail(of: outgoing, until: outgoingEnd)
            audibleEnd = measured.audibleEnd
            fadeStart = measured.fadeStart
        }
        let fadesOut = fadeStart != nil
        // Albums that run straight into each other stay gapless unless the song fades out.
        if isContinuousAlbum, !fadesOut { return nil }

        var overlap = defaultOverlap
        if let fadeStart { overlap = min(max(audibleEnd - fadeStart, 3), 10) }
        overlap = min(overlap, max(2, outgoingEnd * 0.3))
        var startTime = max(0, audibleEnd - overlap)

        var introStart: TimeInterval?
        var firstAudible = incomingBaseStart
        if let incoming, let first = firstAudibleTime(in: incoming) {
            firstAudible = max(incomingBaseStart, first)
            if firstAudible > incomingBaseStart + 0.25 { introStart = firstAudible }
        }

        var tempo: AutoMixPlan.Tempo?
        if let outgoingGrid = outgoing?.beat, let incomingGrid = incoming?.beat,
           let match = matchedIncomingGrid(outgoing: outgoingGrid, incoming: incomingGrid) {
            let snapped = outgoingGrid.nearestBeat(to: startTime)
            let beats = max(4, (overlap / outgoingGrid.period / 4).rounded() * 4)
            let snappedOverlap = min(beats * outgoingGrid.period, (audibleEnd - snapped) / (1 + maximumTempoShift))
            if snapped >= 0, snappedOverlap >= 2.5 {
                startTime = snapped
                overlap = snappedOverlap
                introStart = match.beat(atOrAfter: firstAudible)
                tempo = AutoMixPlan.Tempo(outgoing: outgoingGrid.bpm, incoming: match.bpm)
            }
        }

        return AutoMixPlan(
            outgoingKey: outgoingKey,
            incomingKey: incomingKey,
            startTime: startTime,
            overlap: overlap,
            introStart: introStart,
            tempo: tempo
        )
    }

    /// The incoming grid, possibly at half or double tempo, when it is within reach of the outgoing one.
    private static func matchedIncomingGrid(outgoing: BeatGrid, incoming: BeatGrid) -> BeatGrid? {
        let candidates = [1.0, 2.0, 0.5].map { BeatGrid(bpm: incoming.bpm * $0, referenceBeat: incoming.referenceBeat) }
        return candidates
            .filter { abs($0.bpm / outgoing.bpm - 1) <= maximumTempoShift }
            .min { abs($0.bpm / outgoing.bpm - 1) < abs($1.bpm / outgoing.bpm - 1) }
    }

    private static func firstAudibleTime(in analysis: AutoMixWindowAnalysis) -> TimeInterval? {
        guard let index = analysis.levels.firstIndex(where: { $0 > silenceFloor }) else { return nil }
        // Only skip real lead-in silence, not a long quiet intro.
        let time = analysis.time(ofFrame: index)
        return time <= 6 ? time : nil
    }

    private static func tail(of analysis: AutoMixWindowAnalysis, until end: TimeInterval) -> (audibleEnd: TimeInterval, fadeStart: TimeInterval?) {
        let usable = analysis.levels.indices.filter { analysis.time(ofFrame: $0) < end }
        guard let lastLoud = usable.last(where: { analysis.levels[$0] > silenceFloor }) else { return (end, nil) }
        let audibleEnd = min(end, analysis.time(ofFrame: lastLoud + 1))

        let loud = usable.map { analysis.levels[$0] }.filter { $0 > silenceFloor }.sorted()
        guard loud.count > 40 else { return (audibleEnd, nil) }
        let body = loud[loud.count * 3 / 4]

        // Average of the last two seconds before the audible end against the body level.
        let frames = Int(2 / analysis.frameDuration)
        let tailRange = max(0, lastLoud - frames)...lastLoud
        let tailLevel = tailRange.map { analysis.levels[$0] }.reduce(0, +) / Float(tailRange.count)
        guard tailLevel < body - 10 else { return (audibleEnd, nil) }

        // Walk back while the level stays well below the body to find where the fade begins.
        var index = lastLoud
        while index > 0, analysis.levels[index - 1] < body - 8 { index -= 1 }
        return (audibleEnd, analysis.time(ofFrame: index))
    }
}
