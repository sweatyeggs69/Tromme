import SwiftUI

/// A line of word-synced lyrics. While it's the active line, each word
/// brightens as it's sung; otherwise it's dimmed like any other line.
///
/// The player only publishes its time every half second, which is too coarse
/// for word timing, so the time is extrapolated from the last reported value
/// on every frame while playing.
struct WordSyncedLyricText: View {
    let words: [LyricsWord]
    let isActive: Bool
    /// Last time the player reported, and when it reported it.
    let anchorTime: TimeInterval
    let anchorDate: Date
    let isPlaying: Bool

    /// Never extrapolate further than this past a report, so a stalled
    /// stream doesn't run the highlight ahead of the audio.
    private static let maxExtrapolation: TimeInterval = 1
    private static let dimOpacity = 0.3

    var body: some View {
        TimelineView(.animation(paused: !isActive || !isPlaying)) { context in
            let time = isPlaying
                ? anchorTime + min(max(context.date.timeIntervalSince(anchorDate), 0), Self.maxExtrapolation)
                : anchorTime
            Text(attributedLine(at: time))
        }
    }

    private func attributedLine(at time: TimeInterval) -> AttributedString {
        words.reduce(into: AttributedString()) { line, word in
            var run = AttributedString(word.text)
            run.swiftUI.foregroundColor = Color.white.opacity(opacity(of: word, at: time))
            line.append(run)
        }
    }

    private func opacity(of word: LyricsWord, at time: TimeInterval) -> Double {
        guard isActive else { return Self.dimOpacity }
        let span = max(word.endTime - word.time, 0.05)
        let progress = min(max((time - word.time) / span, 0), 1)
        return Self.dimOpacity + (1 - Self.dimOpacity) * progress
    }
}

#Preview {
    WordSyncedLyricText(
        words: [
            LyricsWord(time: 0, endTime: 0.4, text: "Is "),
            LyricsWord(time: 0.4, endTime: 0.8, text: "this "),
            LyricsWord(time: 0.8, endTime: 1.2, text: "the "),
            LyricsWord(time: 1.2, endTime: 2.0, text: "real "),
            LyricsWord(time: 2.0, endTime: 2.9, text: "life?")
        ],
        isActive: true,
        anchorTime: 1.0,
        anchorDate: .now,
        isPlaying: false
    )
    .font(.system(size: 32, weight: .bold))
    .padding()
    .background(.black)
}
