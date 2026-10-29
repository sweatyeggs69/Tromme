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
    /// Shorter wait when the lyrics mark exactly where the singing stops (a closing blank row).
    private static let markedLastLyricPadding: TimeInterval = 1
    /// Lyrics closer than this to the start of the incoming song leave no room for a mix.
    private static let minimumIntroRoom: TimeInterval = 1
    /// An outro longer than this after the last lyric is shortened: it plays for
    /// `shortenedOutro` minus `shortenedOverlap`, then the mix covers the rest.
    private static let longOutro: TimeInterval = 28
    private static let shortenedOutro: TimeInterval = 22
    private static let shortenedOverlap: TimeInterval = 8
    /// The mix completes this long before the incoming song's first lyric.
    private static let lyricLead: TimeInterval = 1
    /// Mixes this long or longer get a low-pass sweep; shorter ones are a plain crossfade.
    private static let filteredOverlap: TimeInterval = 3
    /// Shortest fade-in for a song whose lyrics start almost straight away.
    private static let quickestFadeIn: TimeInterval = 0.5
    /// Longest the outgoing outro keeps sounding once the new song is at full volume.
    private static let longestTail: TimeInterval = 4
    /// Mixes shorter than this sound like a glitch, so the songs change normally instead.
    private static let shortestMix: TimeInterval = 3
    /// Default length of the plain crossfade (free tier and songs matched by `AutoMixGenreRules`).
    static let defaultCrossfadeLength: TimeInterval = 3

    /// - Parameters:
    ///   - outgoingEnd: Track time where the outgoing track stops (duration or stop marker).
    ///   - incomingBaseStart: The incoming track's start marker, or 0.
    ///   - outgoingVocalEnd: Where the outgoing song's outro begins, from its lyrics.
    ///   - outgoingLastLyricEnd: Where the last lyric finishes; the mix never starts before it.
    ///   - outgoingLastLyricMarked: The lyrics mark that end exactly, so less padding is needed.
    ///   - incomingVocalStart: The incoming song's first lyric.
    /// - Returns: nil when the lyrics run too close to either song's edge to mix, or leave
    ///   room only for a mix shorter than `shortestMix`.
    static func plan(
        outgoingKey: String,
        incomingKey: String,
        outgoingEnd: TimeInterval,
        incomingBaseStart: TimeInterval,
        outgoingVocalEnd: TimeInterval?,
        outgoingLastLyricEnd: TimeInterval?,
        outgoingLastLyricMarked: Bool = false,
        incomingVocalStart: TimeInterval?
    ) -> AutoMixPlan? {
        if let lyricEnd = outgoingLastLyricEnd, outgoingEnd - lyricEnd < minimumOutroRoom { return nil }
        if let vocalStart = incomingVocalStart, vocalStart - incomingBaseStart < minimumIntroRoom { return nil }

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

        // The last lyric is sung in full, plus a little room for it to ring out, before
        // anything changes; a short outro gives up some of that room for the mix itself.
        var startTime = max(0, mixEnd - overlap)
        let padding = outgoingLastLyricMarked ? markedLastLyricPadding : lastLyricPadding
        if let lyricEnd = outgoingLastLyricEnd, startTime < lyricEnd + padding {
            startTime = max(startTime, min(lyricEnd + padding, mixEnd - minimumOverlap))
            overlap = max(mixEnd - startTime, minimumOverlap)
        }

        // Incoming side: the new song is at full volume about a second before its first lyric.
        // A long intro is joined part-way through so the mix ends there; with a short one the
        // new song comes up quickly and the outgoing outro tails off underneath it.
        var introStart: TimeInterval?
        var incomingFade: TimeInterval?
        if let vocalStart = incomingVocalStart {
            let room = vocalStart - lyricLead - incomingBaseStart
            if room > overlap + 0.5 {
                introStart = vocalStart - lyricLead - overlap
            } else if room < overlap {
                let fade = max(room, quickestFadeIn)
                incomingFade = fade
                // The outro only tails under the new song's vocals briefly.
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
            filter: overlap >= filteredOverlap ? .mellow : .none,
            incomingFade: incomingFade
        )
    }

    /// A plain crossfade over the outgoing song's last seconds: both songs play whole, with no
    /// lyric timing, intro skip or filter.
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
