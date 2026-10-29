import Foundation

/// Chooses where and how a track hands over to the next from their analyses.
enum AutoMixPlanner {
    private static let silenceFloor: Float = -50
    private static let defaultOverlap: TimeInterval = 5
    private static let maximumOverlap: TimeInterval = 12
    private static let minimumOverlap: TimeInterval = 2.5
    /// The next song's first lyric within this many seconds of its start means a plain crossfade.
    private static let basicCrossfadeIntro: TimeInterval = 4
    private static let minimumVocalTail: TimeInterval = 3
    /// An instrumental intro or outro at least this long can sit under the other track.
    private static let instrumentalSpan: TimeInterval = 6
    /// An outro longer than this after the last lyric is shortened: it plays for
    /// `shortenedOutro` minus the overlap, then the mix covers the rest.
    private static let longOutro: TimeInterval = 20
    private static let shortenedOutro: TimeInterval = 14
    /// Larger tempo gaps aren't stretched: the time-stretch becomes audible as warble.
    private static let maximumTempoShift = 0.04

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
        outgoingWindow: (TimeInterval) -> AutoMixWindowAnalysis?,
        outgoingOutroStart: TimeInterval?,
        incoming: AutoMixWindowAnalysis?,
        outgoingVocalEnd: TimeInterval?,
        incomingVocalStart: TimeInterval?,
        isContinuousAlbum: Bool
    ) -> AutoMixPlan? {
        var audibleEnd = outgoingEnd
        var fadeStart: TimeInterval?
        // A long instrumental outro is cut short: the mix ends a little into it instead of
        // waiting for the whole outro. Lyrics mark where it starts; without them the audio
        // analysis does (the beat drops out or the level falls).
        let outroFrom = outgoingVocalEnd ?? outgoingOutroStart
        let outgoing: AutoMixWindowAnalysis?
        var shortened = false
        if let outroFrom, outgoingEnd - outroFrom > longOutro {
            audibleEnd = outroFrom + shortenedOutro
            shortened = true
            outgoing = outgoingWindow(audibleEnd)
        } else {
            outgoing = outgoingWindow(outgoingEnd)
            if let outgoing {
                let measured = tail(of: outgoing, until: outgoingEnd)
                audibleEnd = measured.audibleEnd
                fadeStart = measured.fadeStart
            }
        }
        // Tracks in order on the same album are never mixed; they stay gapless.
        if isContinuousAlbum { return nil }

        var overlap = defaultOverlap
        if let fadeStart { overlap = min(max(audibleEnd - fadeStart, 3), maximumOverlap) }
        // With no beat left at the end (drums dropped out, ambient or guitar wash), nothing
        // rhythmic can clash, so blend longer and without tempo changes.
        let beatlessTail = !shortened && (outgoing.map { $0.edgeBeat == nil } ?? false)
        if beatlessTail { overlap = max(overlap, 8) }
        if shortened { overlap = 6 }
        overlap = min(overlap, max(2, outgoingEnd * 0.3))
        var startTime = max(0, audibleEnd - overlap)

        var introStart: TimeInterval?
        var firstAudible = incomingBaseStart
        var incomingFadesIn = false
        if let incoming {
            if let first = firstAudibleTime(in: incoming) {
                firstAudible = max(incomingBaseStart, first)
                if firstAudible > incomingBaseStart + 0.25 { introStart = firstAudible }
            }
            if let fadeIn = fadeInLength(of: incoming, from: firstAudible) {
                incomingFadesIn = true
                // Let the outgoing tail run under the whole fade-in.
                startTime = min(startTime, audibleEnd - min(fadeIn, maximumOverlap))
            }
        }

        // Vocals: an instrumental outro can be overlapped for longer, and an instrumental
        // intro can sit under the outgoing tail. Either way keep the two vocals apart.
        if !shortened, let outroFrom, audibleEnd - outroFrom >= instrumentalSpan {
            startTime = min(startTime, max(outroFrom + 0.5, audibleEnd - maximumOverlap))
        }
        if let incomingVocalStart {
            let intro = incomingVocalStart - firstAudible
            if intro >= instrumentalSpan {
                startTime = min(startTime, audibleEnd - min(intro, maximumOverlap))
            }
        }
        startTime = max(0, min(startTime, audibleEnd - minimumOverlap))
        // Never fade the outgoing song while it is still being sung. A song that ends right
        // after its last lyric gets a short mix instead.
        if let outgoingVocalEnd {
            startTime = max(startTime, min(outgoingVocalEnd, audibleEnd - minimumVocalTail))
        }
        overlap = audibleEnd - startTime
        // Where the outgoing song has faded out completely.
        var mixEnd = audibleEnd

        // The mix finishes before the incoming song's first lyric. A mix squeezed by that keeps
        // its start and simply ends sooner, cutting the outgoing tail, rather than being pushed
        // to the very end of the song.
        var vocalLimit: TimeInterval?
        var squeezed = false
        // Singing starts almost immediately: no room for a clean mix, so do a plain crossfade
        // with no filter or tempo change instead of squeezing one in.
        let basicCrossfade = incomingVocalStart.map { $0 - firstAudible < basicCrossfadeIntro } ?? false
        if let incomingVocalStart, !basicCrossfade {
            let limit = max(incomingVocalStart - firstAudible - 1, 1.5)
            vocalLimit = limit
            if overlap > limit {
                overlap = limit
                mixEnd = startTime + overlap
                squeezed = true
            }
        }

        var tempo: AutoMixPlan.Tempo?
        if !basicCrossfade, let outgoingGrid = outgoing?.edgeBeat, let incomingGrid = incoming?.edgeBeat,
           let match = matchedIncomingGrid(outgoing: outgoingGrid, incoming: incomingGrid) {
            // Snap forward so vocal gaps chosen above are kept.
            let snapped = outgoingGrid.beat(atOrAfter: startTime)
            let beats = max(4, (overlap / outgoingGrid.period / 4).rounded() * 4)
            let incomingPeriod = 60 / match.bpm
            let snappedOverlap = min(beats * incomingPeriod, (mixEnd - snapped) / (1 + maximumTempoShift), vocalLimit ?? .infinity)
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
            tempo: tempo,
            incomingFadesIn: incomingFadesIn,
            filter: basicCrossfade ? .none : filterStyle(outgoing: outgoing, incoming: incoming, end: outgoingEnd),
            curve: curve(basicCrossfade: basicCrossfade, beatMatched: tempo != nil, naturalFade: fadeStart != nil || incomingFadesIn)
        )
    }

    /// Beat-matched mixes swap mostly in the middle, like a DJ; songs that fade on their own
    /// stay up together longer; everything else keeps constant loudness.
    private static func curve(basicCrossfade: Bool, beatMatched: Bool, naturalFade: Bool) -> AutoMixPlan.Curve {
        if basicCrossfade { return .equalPower }
        if beatMatched { return .smooth }
        return naturalFade ? .overlapping : .equalPower
    }

    /// Fast, loud songs get a high-pass sweep; slower or quieter ones a low-pass sweep.
    private static func filterStyle(outgoing: AutoMixWindowAnalysis?, incoming: AutoMixWindowAnalysis?, end: TimeInterval) -> AutoMixPlan.FilterStyle {
        guard outgoing != nil || incoming != nil else { return .none }
        var score = 0
        if let bpm = outgoing?.beat?.bpm ?? incoming?.beat?.bpm {
            score += bpm >= 108 ? 1 : (bpm < 92 ? -1 : 0)
        }
        if let outgoing {
            let loud = outgoing.levels.indices
                .filter { outgoing.time(ofFrame: $0) < end }
                .map { outgoing.levels[$0] }
                .filter { $0 > silenceFloor }
                .sorted()
            if loud.count > 40 {
                let body = loud[loud.count * 3 / 4]
                score += body > -14 ? 1 : (body < -22 ? -1 : 0)
            }
        }
        if outgoing?.edgeBeat == nil, outgoing != nil { return .mellow }
        if score == 0 { return .none }
        return score > 0 ? .energetic : .mellow
    }

    /// The incoming grid, possibly at half or double tempo, when it is within reach of the outgoing one.
    private static func matchedIncomingGrid(outgoing: BeatGrid, incoming: BeatGrid) -> BeatGrid? {
        let candidates = [1.0, 2.0, 0.5].map { BeatGrid(bpm: incoming.bpm * $0, referenceBeat: incoming.referenceBeat) }
        return candidates
            .filter { abs($0.bpm / outgoing.bpm - 1) <= maximumTempoShift }
            .min { abs($0.bpm / outgoing.bpm - 1) < abs($1.bpm / outgoing.bpm - 1) }
    }

    /// How long a fade-in lasts: from the first audible moment until the level is within
    /// 6 dB of the song's body. Nil when the song starts at full strength.
    private static func fadeInLength(of analysis: AutoMixWindowAnalysis, from start: TimeInterval) -> TimeInterval? {
        let loud = analysis.levels.filter { $0 > silenceFloor }.sorted()
        guard loud.count > 40 else { return nil }
        let body = loud[loud.count * 3 / 4]
        let startIndex = max(0, Int((start - analysis.windowStart) / analysis.frameDuration))
        guard startIndex + 20 < analysis.levels.count else { return nil }
        // Smooth over half a second so a single beat doesn't look like the body.
        let smoothing = 10
        guard analysis.levels[startIndex..<(startIndex + smoothing)].reduce(0, +) / Float(smoothing) < body - 12 else { return nil }
        for index in startIndex..<(analysis.levels.count - smoothing) {
            let average = analysis.levels[index..<(index + smoothing)].reduce(0, +) / Float(smoothing)
            if average >= body - 6 {
                let length = analysis.time(ofFrame: index) - start
                return length >= 3 ? length : nil
            }
        }
        return nil
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
