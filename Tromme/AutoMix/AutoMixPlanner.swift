import Foundation

/// Chooses where and how a track hands over to the next from their synced lyrics.
enum AutoMixPlanner {
    private static let defaultOverlap: TimeInterval = 5
    private static let maximumOverlap: TimeInterval = 12
    private static let minimumOverlap: TimeInterval = 1.5
    /// Room needed after the last lyric to wait for it to finish completely.
    private static let minimumFullLyricMix: TimeInterval = 2.5
    /// An outro longer than this after the last lyric is shortened: it plays for
    /// `shortenedOutro` minus `shortenedOverlap`, then the mix covers the rest.
    private static let longOutro: TimeInterval = 20
    private static let shortenedOutro: TimeInterval = 14
    private static let shortenedOverlap: TimeInterval = 8
    /// The mix completes this long before the incoming song's first lyric.
    private static let lyricLead: TimeInterval = 1
    /// Mixes this long or longer get a low-pass sweep; shorter ones are a plain crossfade.
    private static let filteredOverlap: TimeInterval = 6

    /// - Parameters:
    ///   - outgoingEnd: Track time where the outgoing track stops (duration or stop marker).
    ///   - incomingBaseStart: The incoming track's start marker, or 0.
    ///   - outgoingVocalEnd: Where the outgoing song's outro begins, from its lyrics.
    ///   - outgoingLastLyricEnd: Where the last lyric finishes; the mix waits for it when it can.
    ///   - outgoingLastLyricMostlySung: The earliest the mix may start (75% into the last lyric).
    ///   - incomingVocalStart: The incoming song's first lyric.
    static func plan(
        outgoingKey: String,
        incomingKey: String,
        outgoingEnd: TimeInterval,
        incomingBaseStart: TimeInterval,
        outgoingVocalEnd: TimeInterval?,
        outgoingLastLyricEnd: TimeInterval?,
        outgoingLastLyricMostlySung: TimeInterval?,
        incomingVocalStart: TimeInterval?
    ) -> AutoMixPlan {
        // Outgoing side: the outro sets the length. A short outro gets a short mix; a long one
        // is cut short so the next song comes in a little after the last lyric.
        var mixEnd = outgoingEnd
        var overlap = defaultOverlap
        if let vocalEnd = outgoingVocalEnd {
            let outro = max(0, outgoingEnd - vocalEnd)
            if outro > longOutro {
                mixEnd = vocalEnd + shortenedOutro
                overlap = shortenedOverlap
            } else {
                overlap = min(max(outro, minimumOverlap), maximumOverlap)
            }
        }

        // The last lyric is sung in full before anything changes when the song leaves room for
        // a mix after it; otherwise it is at least 75% sung, even if that leaves a short mix.
        var startTime = max(0, mixEnd - overlap)
        let floor: TimeInterval? = if let lyricEnd = outgoingLastLyricEnd, mixEnd - lyricEnd >= minimumFullLyricMix {
            lyricEnd
        } else {
            outgoingLastLyricMostlySung
        }
        if let floor, startTime < floor {
            startTime = floor
            overlap = max(mixEnd - startTime, minimumOverlap)
        }

        // Incoming side: the mix completes about a second before the first lyric. A long intro
        // is joined part-way through so it lines up; a short one shortens the mix instead.
        var introStart: TimeInterval?
        if let vocalStart = incomingVocalStart {
            let room = vocalStart - lyricLead - incomingBaseStart
            if room > overlap + 0.5 {
                introStart = vocalStart - lyricLead - overlap
            } else {
                overlap = max(min(overlap, room), minimumOverlap)
            }
        }

        return AutoMixPlan(
            outgoingKey: outgoingKey,
            incomingKey: incomingKey,
            startTime: startTime,
            overlap: overlap,
            introStart: introStart,
            filter: overlap >= filteredOverlap ? .mellow : .none
        )
    }
}
