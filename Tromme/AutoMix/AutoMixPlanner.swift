import Foundation

enum AutoMixPlanner {
    private static let defaultOverlap: TimeInterval = 5
    private static let maximumOverlap: TimeInterval = 10
    private static let minimumOverlap: TimeInterval = 1.5
    private static let minimumOutroRoom: TimeInterval = 3
    private static let lastLyricPadding: TimeInterval = 2.5
    private static let markedLastLyricPadding: TimeInterval = 1
    private static let outroHold: TimeInterval = 26
    private static let playedOutStart: TimeInterval = 55
    private static let playedOutRate: TimeInterval = 1.5
    private static let lyricLead: TimeInterval = 1
    private static let filteredOverlap: TimeInterval = 3
    private static let quickestFadeIn: TimeInterval = 0.5
    private static let longestTail: TimeInterval = 4
    private static let shortestMix: TimeInterval = 3
    static let defaultCrossfadeLength: TimeInterval = 3

    static func plan(
        outgoingKey: String,
        incomingKey: String,
        outgoingEnd: TimeInterval,
        incomingBaseStart: TimeInterval,
        outgoingVocalEnd: TimeInterval?,
        outgoingLastLyricEnd: TimeInterval?,
        outgoingLastLyricMarked: Bool = false,
        outgoingSingingEnd: TimeInterval? = nil,
        incomingVocalStart: TimeInterval?
    ) -> AutoMixPlan? {
        if let lyricEnd = outgoingLastLyricEnd, outgoingEnd - lyricEnd < minimumOutroRoom { return nil }

        var mixEnd = outgoingEnd
        var overlap = defaultOverlap
        if let vocalEnd = outgoingVocalEnd {
            let singingOutro = outgoingEnd - (outgoingSingingEnd ?? vocalEnd)
            mixEnd = min(outgoingEnd, vocalEnd + outroHold + playedOutRate * max(0, singingOutro - playedOutStart))
            overlap = min(max(mixEnd - vocalEnd, minimumOverlap), maximumOverlap)
        }

        var startTime = max(0, mixEnd - overlap)
        let padding = outgoingLastLyricMarked ? markedLastLyricPadding : lastLyricPadding
        if let lyricEnd = outgoingLastLyricEnd, startTime < lyricEnd + padding {
            startTime = max(startTime, min(lyricEnd + padding, mixEnd - minimumOverlap))
            overlap = max(mixEnd - startTime, minimumOverlap)
        }

        var introStart: TimeInterval?
        var incomingFade: TimeInterval?
        if let vocalStart = incomingVocalStart {
            let room = vocalStart - lyricLead - incomingBaseStart
            if room > overlap + 0.5 {
                introStart = vocalStart - lyricLead - overlap
            } else if room < overlap {
                let fade = max(room, quickestFadeIn)
                incomingFade = fade
                overlap = min(overlap, fade + longestTail)
                startTime = max(startTime, mixEnd - overlap)
            }
        }

        guard overlap >= shortestMix else { return nil }

        return AutoMixPlan(
            outgoingKey: outgoingKey,
            incomingKey: incomingKey,
            startTime: startTime,
            overlap: overlap,
            introStart: introStart,
            filter: overlap >= filteredOverlap ? .mellow : .none,
            incomingFade: incomingFade
        )
    }

    static func crossfade(outgoingKey: String, incomingKey: String, outgoingEnd: TimeInterval, length: TimeInterval) -> AutoMixPlan {
        AutoMixPlan(
            outgoingKey: outgoingKey,
            incomingKey: incomingKey,
            startTime: max(0, outgoingEnd - length),
            overlap: length,
            isPlainCrossfade: true
        )
    }
}
