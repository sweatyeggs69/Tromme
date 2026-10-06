import Foundation

/// Parses LRC lyrics, including the enhanced form lrc.red serves for
/// word-synced lyrics, where each word is preceded by its own stamp and the
/// line ends with a stamp marking when the last word finishes:
///
///     [00:03.73]<00:03.73>Is <00:04.14>this <00:04.53>just <00:04.89>fantasy? <00:06.37>
enum LRCParser {
    static func parse(_ lrc: String) -> [LyricsLine] {
        var result: [LyricsLine] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["),
                  let closeBracket = line.firstIndex(of: "]"),
                  let time = seconds(from: line[line.index(after: line.startIndex)..<closeBracket]) else { continue }
            let body = String(line[line.index(after: closeBracket)...])
            let words = parseWords(body)
            let text = words.isEmpty
                ? body.trimmingCharacters(in: .whitespaces)
                : words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            result.append(LyricsLine(time: time, text: text, words: words))
        }
        return result.sorted { $0.time < $1.time }
    }

    static func isWordSynced(_ lrc: String) -> Bool {
        parse(lrc).contains { !$0.words.isEmpty }
    }

    /// Splits `<mm:ss.xx>word <mm:ss.xx>word <mm:ss.xx>` into timed words.
    /// A word ends where the next stamp begins; a trailing stamp with no text
    /// only marks the end of the last word. Returns [] for a plain LRC line.
    private static func parseWords(_ body: String) -> [LyricsWord] {
        var stamps: [(time: TimeInterval, text: String)] = []
        var rest = Substring(body)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">"),
                  let time = seconds(from: rest[rest.index(after: open)..<close]) else { break }
            let afterStamp = rest[rest.index(after: close)...]
            let nextOpen = afterStamp.firstIndex(of: "<") ?? afterStamp.endIndex
            stamps.append((time, String(afterStamp[..<nextOpen])))
            rest = afterStamp[nextOpen...]
        }

        var words: [LyricsWord] = []
        for (i, stamp) in stamps.enumerated() where !stamp.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let end = i + 1 < stamps.count ? stamps[i + 1].time : stamp.time + 1
            words.append(LyricsWord(time: stamp.time, endTime: max(end, stamp.time), text: stamp.text))
        }
        return words
    }

    /// Reads `mm:ss.xx`; returns nil for metadata tags like `[ti:…]` or `[length:05:56]`.
    private static func seconds(from timestamp: Substring) -> TimeInterval? {
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}
