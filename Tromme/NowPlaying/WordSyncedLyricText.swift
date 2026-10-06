import SwiftUI

/// A line of word-synced lyrics. While it's the active line, each word is
/// wiped bright as it's sung (see `WordWipeTextRenderer`); otherwise it's
/// dimmed like any other line.
///
/// The time comes from `LyricsClock`, re-evaluated on every frame while playing.
struct WordSyncedLyricText: View {
    let words: [LyricsWord]
    let isActive: Bool
    let clock: LyricsClock

    var body: some View {
        TimelineView(.animation(paused: !isActive || !clock.isPlaying)) { context in
            lineText
                .textRenderer(WordWipeTextRenderer(time: clock.time(at: context.date), activeAmount: isActive ? 1 : 0))
        }
    }

    /// Tags each word with its timing for the renderer. Trailing spaces are
    /// left untagged so a word's wipe and growth are centered on its letters.
    private var lineText: Text {
        words.reduce(Text(verbatim: "")) { line, word in
            let leading = word.text.first?.isWhitespace == true ? " " : ""
            let trailing = word.text.last?.isWhitespace == true ? " " : ""
            let timed = Text(verbatim: word.text.trimmingCharacters(in: .whitespaces))
                .customAttribute(WordWipeTextRenderer.Timing(start: word.time, end: word.endTime))
            return Text("\(line)\(Text(verbatim: leading))\(timed)\(Text(verbatim: trailing))")
        }
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
        clock: LyricsClock(anchorTime: 1.0)
    )
    .font(.system(size: 32, weight: .bold))
    .foregroundStyle(.white)
    .padding()
    .background(.black)
}
