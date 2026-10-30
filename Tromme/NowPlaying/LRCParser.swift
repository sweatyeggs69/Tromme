import Foundation

enum LRCParser {
    static let breakThreshold: TimeInterval = 5

    static func parse(_ lrc: String, trackDuration: TimeInterval? = nil) -> [LyricsLine] {
        var result: [(line: LyricsLine, isBackground: Bool)] = []
        var endMarkers: [TimeInterval] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[bg:"), line.hasSuffix("]") {
                line = String(line.dropFirst(4).dropLast())
                let words = parseWords(line)
                guard let first = words.first else { continue }
                let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                result.append((LyricsLine(time: first.time, text: text, words: words), true))
                continue
            }
            guard line.hasPrefix("["),
                  let closeBracket = line.firstIndex(of: "]"),
                  let time = seconds(from: line[line.index(after: line.startIndex)..<closeBracket]) else { continue }
            let body = String(line[line.index(after: closeBracket)...])
            let words = parseWords(body)
            let text = words.isEmpty
                ? body.trimmingCharacters(in: .whitespaces)
                : words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                endMarkers.append(time)
                continue
            }
            if words.isEmpty, let (main, echo) = splittingTrailingBacking(text) {
                var primary = LyricsLine(time: time, text: main)
                primary.backing = [LyricsLine(time: time, text: echo)]
                result.append((primary, false))
                continue
            }
            result.append((LyricsLine(time: time, text: text, words: words), false))
        }
        let sorted = result.sorted { $0.line.time < $1.line.time }
        return insertingBreaks(into: foldingBacking(sorted), endMarkers: endMarkers.sorted(), trackDuration: trackDuration)
    }

    private static func foldingBacking(_ entries: [(line: LyricsLine, isBackground: Bool)]) -> [LyricsLine] {
        var result: [LyricsLine] = []
        for (line, isBackground) in entries {
            guard var primary = result.popLast() else {
                result.append(line)
                continue
            }
            let primaryEnd = primary.words.last?.endTime
            let overlaps = primaryEnd.map { line.time < $0 - 0.05 } ?? false
            if line.words.isEmpty, primary.words.isEmpty, isParenthesized(line.text), !isParenthesized(primary.text) {
                primary.backing.append(LyricsLine(time: line.time, text: String(line.text.dropFirst().dropLast())))
                result.append(primary)
            } else if overlaps, !line.words.isEmpty, isParenthesized(primary.text), !isParenthesized(line.text) {
                var promoted = line.withTime(primary.time)
                promoted.backing = [primary]
                result.append(promoted)
            } else if isBackground || (overlaps && !line.words.isEmpty) {
                primary.backing.append(line)
                result.append(primary)
            } else {
                result.append(primary)
                result.append(line)
            }
        }
        return result
    }

    private static func splittingTrailingBacking(_ text: String) -> (main: String, backing: String)? {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let main = text[..<open].trimmingCharacters(in: .whitespaces)
        let backing = text[text.index(after: open)..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
        guard !main.isEmpty, !backing.isEmpty, !main.contains("("), !backing.contains(")") else { return nil }
        return (main, backing)
    }

    private static func isParenthesized(_ text: String) -> Bool {
        text.hasPrefix("(") && text.hasSuffix(")")
    }

    private static func insertingBreaks(into lines: [LyricsLine], endMarkers: [TimeInterval], trackDuration: TimeInterval?) -> [LyricsLine] {
        guard let first = lines.first else { return lines }
        var result: [LyricsLine] = []
        if first.time > breakThreshold {
            result.append(LyricsLine(time: 0, text: "", isBreak: true))
        }
        for (index, line) in lines.enumerated() {
            result.append(line)
            guard index + 1 < lines.count else {
                if let trackDuration {
                    let end = line.lastWordEnd
                        ?? endMarkers.first(where: { $0 > line.time })
                        ?? line.time + 1.5 + 0.08 * Double(line.text.count)
                    if trackDuration - end > breakThreshold {
                        result.append(LyricsLine(time: end, text: "", isBreak: true))
                    }
                }
                break
            }
            let next = lines[index + 1]
            let end = endTime(of: line, before: next, endMarkers: endMarkers)
            if next.time - end > breakThreshold {
                result.append(LyricsLine(time: end, text: "", isBreak: true))
            }
        }
        return result
    }

    private static func endTime(of line: LyricsLine, before next: LyricsLine, endMarkers: [TimeInterval]) -> TimeInterval {
        if let last = line.lastWordEnd { return last }
        if let marker = endMarkers.first(where: { $0 > line.time && $0 < next.time }) { return marker }
        return min(next.time, line.time + 1.5 + 0.08 * Double(line.text.count))
    }

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

    private static func seconds(from timestamp: Substring) -> TimeInterval? {
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}
