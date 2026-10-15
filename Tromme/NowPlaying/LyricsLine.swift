import Foundation
import Observation

struct LyricsLine: Identifiable, Sendable {
    let id = UUID()
    let time: TimeInterval
    let text: String
    /// Per-word timing when the lyrics are word-synced; empty for line-synced lyrics.
    var words: [LyricsWord] = []
    /// A music note shown in a long instrumental gap rather than a lyric.
    var isBreak = false
    /// Backing vocals sung over this line, shown smaller beneath it.
    var backing: [LyricsLine] = []

    func withTime(_ time: TimeInterval) -> LyricsLine {
        var line = LyricsLine(time: time, text: text, words: words)
        line.backing = backing
        return line
    }

    /// When the last word of the line or of any backing line finishes, if word-synced.
    var lastWordEnd: TimeInterval? {
        ([words.last?.endTime] + backing.map { $0.words.last?.endTime }).compactMap { $0 }.max()
    }
}
