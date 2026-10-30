import Foundation

enum AutoMixPlanner {
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
        outgoingLyricsEnd: TimeInterval,
        outgoingLyricsEndMarked: Bool,
        incomingVocalStart: TimeInterval?
    ) -> AutoMixPlan? {
        let outro = outgoingEnd - outgoingLyricsEnd
        guard outro >= minimumOutroRoom else { return nil }

        let mixEnd = min(outgoingEnd, outgoingLyricsEnd + outroHold + playedOutRate * max(0, outro - playedOutStart))
        var overlap = min(max(mixEnd - outgoingLyricsEnd, minimumOverlap), maximumOverlap)
        var startTime = max(mixEnd - overlap, outgoingLyricsEnd + (outgoingLyricsEndMarked ? markedLastLyricPadding : lastLyricPadding))
        startTime = min(startTime, mixEnd - minimumOverlap)
        overlap = mixEnd - startTime

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
