import Foundation

/// Chooses where and how a track hands over to the next from their synced lyrics.
enum AutoMixPlanner {
    private static let defaultOverlap: TimeInterval = 5
    private static let maximumOverlap: TimeInterval = 12
    private static let minimumOverlap: TimeInterval = 1.5
    /// Lyrics closer than this to the end of the outgoing song leave no room for a mix.
    private static let minimumOutroRoom: TimeInterval = 3
    /// Held notes and echoes ring past the last timed word, so the mix waits this much longer.
    private static let lastLyricPadding: TimeInterval = 2.5
    /// Lyrics closer than this to the start of the incoming song leave no room for a mix.
    private static let minimumIntroRoom: TimeInterval = 1
    /// An outro longer than this after the last lyric is shortened: it plays for
    /// `shortenedOutro` minus `shortenedOverlap`, then the mix covers the rest.
    private static let longOutro: TimeInterval = 20
    private static let shortenedOutro: TimeInterval = 14
    private static let shortenedOverlap: TimeInterval = 8
    /// The mix completes this long before the incoming song's first lyric.
    private static let lyricLead: TimeInterval = 1
    /// Mixes this long or longer get a low-pass sweep; shorter ones are a plain crossfade.
    private static let filteredOverlap: TimeInterval = 6
    /// Songs that keep their whole intro or outro get only a short crossfade at the seam.
    private static let seamOverlap: TimeInterval = 3

    /// - Parameters:
    ///   - outgoingEnd: Track time where the outgoing track stops (duration or stop marker).
    ///   - incomingBaseStart: The incoming track's start marker, or 0.
    ///   - outgoingVocalEnd: Where the outgoing song's outro begins, from its lyrics.
    ///   - outgoingLastLyricEnd: Where the last lyric finishes; the mix never starts before it.
    ///   - incomingVocalStart: The incoming song's first lyric.
    ///   - keepOutgoingOutro: Keep the outgoing song's outro whole (see `AutoMixGenreRules`).
    ///   - keepIncomingIntro: Keep the incoming song's intro whole.
    /// - Returns: nil when the lyrics run too close to either song's edge to mix.
    static func plan(
        outgoingKey: String,
        incomingKey: String,
        outgoingEnd: TimeInterval,
        incomingBaseStart: TimeInterval,
        outgoingVocalEnd: TimeInterval?,
        outgoingLastLyricEnd: TimeInterval?,
        incomingVocalStart: TimeInterval?,
        keepOutgoingOutro: Bool,
        keepIncomingIntro: Bool
    ) -> AutoMixPlan? {
        if let lyricEnd = outgoingLastLyricEnd, outgoingEnd - lyricEnd < minimumOutroRoom { return nil }
        if let vocalStart = incomingVocalStart, vocalStart - incomingBaseStart < minimumIntroRoom { return nil }

        // Outgoing side: the outro sets the length. A short outro gets a short mix; a long one
        // is cut short so the next song comes in a little after the last lyric.
        var mixEnd = outgoingEnd
        var overlap = defaultOverlap
        if let vocalEnd = outgoingVocalEnd {
            let outro = max(0, outgoingEnd - vocalEnd)
            if outro > longOutro, !keepOutgoingOutro {
                mixEnd = vocalEnd + shortenedOutro
                overlap = shortenedOverlap
            } else {
                overlap = min(max(outro, minimumOverlap), maximumOverlap)
            }
        }

        if keepOutgoingOutro || keepIncomingIntro { overlap = min(overlap, seamOverlap) }

        // The last lyric is sung in full, plus a little room for it to ring out, before
        // anything changes; a short outro gives up some of that room for the mix itself.
        var startTime = max(0, mixEnd - overlap)
        if let lyricEnd = outgoingLastLyricEnd, startTime < lyricEnd + lastLyricPadding {
            startTime = max(startTime, min(lyricEnd + lastLyricPadding, mixEnd - minimumOverlap))
            overlap = max(mixEnd - startTime, minimumOverlap)
        }

        // Incoming side: the mix completes about a second before the first lyric. A long intro
        // is joined part-way through so it lines up; a short one shortens the mix instead.
        var introStart: TimeInterval?
        if let vocalStart = incomingVocalStart {
            let room = vocalStart - lyricLead - incomingBaseStart
            if room > overlap + 0.5, !keepIncomingIntro {
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
