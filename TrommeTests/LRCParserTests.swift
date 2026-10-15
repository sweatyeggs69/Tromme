import Testing
@testable import Tromme

struct LRCParserTests {
    @Test func parsesLineSyncedLyrics() {
        let lines = LRCParser.parse("[00:12.50]Hello\n[00:15.00]World")
        let hello = lines.first { $0.text == "Hello" }
        let world = lines.first { $0.text == "World" }
        #expect(hello?.time == 12.5)
        #expect(world?.time == 15.0)
        #expect(hello?.words.isEmpty == true)
    }

    @Test func parsesWordSyncedLyrics() {
        let lines = LRCParser.parse("[00:03.00]<00:03.00>Is <00:04.00>this <00:05.00>")
        let line = lines.first { $0.text == "Is this" }
        #expect(line?.words.count == 2)
        #expect(line?.words.first?.time == 3.0)
    }

    @Test func ignoresNonLyricLines() {
        let lines = LRCParser.parse("[ar:Artist]\nnot a lyric line")
        #expect(lines.allSatisfy { $0.isBreak })
    }
}
