import Foundation

enum LrcRedLyricsProvider {
    private static let baseURL = URL(string: "https://lrc.red")!

    private static let maxCandidates = 4

    struct TimedLyrics: Sendable {
        var wordSynced: [String] = []
        var lineSynced: [String] = []
    }

    static func timedLyrics(title: String, artist: String, duration: TimeInterval?) async -> TimedLyrics {
        let candidates = await matchingISRCs(title: title, artist: artist, duration: duration)
        #if DEBUG
        print("[Lyrics] lrc.red candidates for \(title): \(candidates)")
        #endif
        guard !candidates.isEmpty else { return TimedLyrics() }

        let lrcs = await withTaskGroup(of: (rank: Int, lrc: FetchedLRC?).self) { group in
            for (rank, isrc) in candidates.enumerated() {
                group.addTask { (rank, await lrc(isrc: isrc, duration: duration)) }
            }
            var results: [(rank: Int, lrc: FetchedLRC)] = []
            for await (rank, lrc) in group {
                if let lrc { results.append((rank, lrc)) }
            }
            return results.sorted { $0.rank < $1.rank }.map(\.lrc)
        }

        var seen = Set<String>()
        let distinct = lrcs.filter { seen.insert($0.text).inserted }
        return TimedLyrics(
            wordSynced: distinct.filter(\.isWordSynced).map(\.text),
            lineSynced: distinct.filter { !$0.isWordSynced }.map(\.text)
        )
    }

    // MARK: - Search

    private struct SearchResponse: Decodable {
        let hits: [Hit]
    }

    private struct Hit: Decodable {
        let isrc: String
        let title: String
        let artist: String
        let duration: Double?
    }

    private static func matchingISRCs(title: String, artist: String, duration: TimeInterval?) async -> [String] {
        let wantedTitle = normalizedTitle(title)
        guard !wantedTitle.isEmpty else { return [] }

        let base = baseTitle(title)
        let titles = base == title ? [title] : [base, title]
        for searchTitle in titles {
            let hits = await search(query: "\(artist) \(searchTitle)")
            let isrcs = rankedISRCs(hits, title: wantedTitle, artist: artist, duration: duration)
            if !isrcs.isEmpty { return isrcs }
        }
        return []
    }

    private static func search(query: String) async -> [Hit] {
        var components = URLComponents(url: baseURL.appending(path: "search.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "q", value: query)]
        guard let url = components.url,
              let data = await LyricsService.fetchWithRetry(url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        return response.hits
    }

    private static func rankedISRCs(_ hits: [Hit], title wantedTitle: String, artist: String, duration: TimeInterval?) -> [String] {
        let wantedArtist = normalized(artist)
        let matches = hits.filter { hit in
            guard normalizedTitle(hit.title) == wantedTitle else { return false }
            let hitArtist = normalized(hit.artist)
            guard !hitArtist.isEmpty,
                  hitArtist.contains(wantedArtist) || wantedArtist.contains(hitArtist) else { return false }
            guard let duration, let hitDuration = hit.duration else { return true }
            return abs(hitDuration - duration) <= LyricsService.syncedDurationTolerance
        }

        let ranked = matches.sorted { a, b in
            guard let duration else { return false }
            return abs((a.duration ?? duration) - duration) < abs((b.duration ?? duration) - duration)
        }
        var seen = Set<String>()
        return ranked.map(\.isrc).filter { seen.insert($0).inserted }.prefix(maxCandidates).map { $0 }
    }

    private struct FetchedLRC: Sendable {
        let text: String
        let isWordSynced: Bool
    }

    private static func lrc(isrc: String, duration: TimeInterval?) async -> FetchedLRC? {
        let url = baseURL.appending(path: "s/\(isrc).lrc")
        guard let data = await LyricsService.fetchWithRetry(url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = LRCParser.parse(text)
        guard let lastTime = lines.map(\.time).max() else { return nil }
        if let duration, lastTime > duration + LyricsService.syncedDurationTolerance {
            #if DEBUG
            print("[Lyrics] lrc.red \(isrc) rejected: last line \(Int(lastTime))s, track \(Int(duration))s")
            #endif
            return nil
        }
        return FetchedLRC(text: text, isWordSynced: lines.contains { !$0.words.isEmpty })
    }

    // MARK: - Matching

    private static func normalizedTitle(_ title: String) -> String {
        normalized(baseTitle(title))
    }

    private static func baseTitle(_ title: String) -> String {
        var base = title.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        if let dash = base.range(of: " - ") {
            base = String(base[..<dash.lowerBound])
        }
        return base.trimmingCharacters(in: .whitespaces)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
