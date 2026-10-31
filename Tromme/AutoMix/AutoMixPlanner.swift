import Foundation

enum AutoMixPlanner {
    private static let targetOverlap: TimeInterval = 6
    static let minimumLastLyricPadding: TimeInterval = 1
    private static let lastLyricPadding: TimeInterval = 3
    private static let markedLastLyricPadding: TimeInterval = 1.5
    private static let outroWaitRate: TimeInterval = 0.2
    private static let lyricLead: TimeInterval = 1
    private static let quickestFadeIn: TimeInterval = 0.5
    private static let longestTail: TimeInterval = 4
    private static let shortestMix: TimeInterval = 2
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
        let padding = outgoingLyricsEndMarked ? markedLastLyricPadding : lastLyricPadding
        let outro = outgoingEnd - outgoingLyricsEnd
        let startTime = min(outgoingLyricsEnd + padding + outroWaitRate * outro, outgoingEnd - shortestMix)
        guard startTime >= outgoingLyricsEnd + minimumLastLyricPadding else { return nil }
        var overlap = min(targetOverlap, outgoingEnd - startTime)

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
            }
        }

        guard overlap >= shortestMix else { return nil }

        return AutoMixPlan(
            outgoingKey: outgoingKey,
            incomingKey: incomingKey,
            startTime: startTime,
            overlap: overlap,
            introStart: introStart,
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
