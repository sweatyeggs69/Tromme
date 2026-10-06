import Foundation

/// Looks up timed lyrics on lrc.red, which keys its catalog by ISRC.
/// Plex doesn't expose a track's ISRC, so the track is matched through
/// `/search.json` first, then the timed lyrics come from `/s/<ISRC>.lrc`.
/// That file carries per-word `<mm:ss.xx>` stamps when the lyrics are
/// word-synced and answers 404 when they have no timing at all.
enum LrcRedLyricsProvider {
    private static let baseURL = URL(string: "https://lrc.red")!

    /// How many matching releases (remasters, compilations…) are checked for
    /// timing, since they don't all carry the same sync level.
    private static let maxCandidates = 4

    /// Returns the best timed LRC for the track: word-synced if any matching
    /// release has it, otherwise line-synced, otherwise nil.
    static func syncedLyrics(title: String, artist: String, duration: TimeInterval?) async -> String? {
        let candidates = await matchingISRCs(title: title, artist: artist, duration: duration)
        guard !candidates.isEmpty else { return nil }

        let lrcs = await withTaskGroup(of: (rank: Int, lrc: FetchedLRC?).self) { group in
            for (rank, isrc) in candidates.enumerated() {
                group.addTask { (rank, await lrc(isrc: isrc)) }
            }
            var results: [(rank: Int, lrc: FetchedLRC)] = []
            for await (rank, lrc) in group {
                if let lrc { results.append((rank, lrc)) }
            }
            return results.sorted { $0.rank < $1.rank }.map(\.lrc)
        }

        return (lrcs.first(where: \.isWordSynced) ?? lrcs.first)?.text
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

    /// ISRCs of search hits for the same song by the same artist, closest
    /// duration first. Searches with version tags dropped first, since text
    /// like "(Taylor's Version)" can crowd the song itself out of the limited
    /// hit list, then retries with the title exactly as given.
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

    /// An LRC that parsed to at least one line, with whether it has per-word timing.
    private struct FetchedLRC: Sendable {
        let text: String
        let isWordSynced: Bool
    }

    private static func lrc(isrc: String) async -> FetchedLRC? {
        let url = baseURL.appending(path: "s/\(isrc).lrc")
        guard let data = await LyricsService.fetchWithRetry(url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = LRCParser.parse(text)
        guard !lines.isEmpty else { return nil }
        return FetchedLRC(text: text, isWordSynced: lines.contains { !$0.words.isEmpty })
    }

    // MARK: - Matching

    /// Drops version tags so "Song (Remastered 2011)" and "Song - Live" match "Song".
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
