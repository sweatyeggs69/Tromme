import Foundation
import Observation

struct LyricsLine: Identifiable, Sendable {
    let id = UUID()
    let time: TimeInterval
    let text: String
    var words: [LyricsWord] = []
    var isBreak = false
    var backing: [LyricsLine] = []

    func withTime(_ time: TimeInterval) -> LyricsLine {
        var line = LyricsLine(time: time, text: text, words: words)
        line.backing = backing
        return line
    }

    var lastWordEnd: TimeInterval? {
        ([words.last?.endTime] + backing.map { $0.words.last?.endTime }).compactMap { $0 }.max()
    }
}
