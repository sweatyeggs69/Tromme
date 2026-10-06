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

    /// Two releases of the same recording rarely differ by more than this.
    private static let durationTolerance: TimeInterval = 5

    /// Returns the best timed LRC for the track: word-synced if any matching
    /// release has it, otherwise line-synced, otherwise nil.
    static func syncedLyrics(title: String, artist: String, duration: TimeInterval?) async -> String? {
        let candidates = await matchingISRCs(title: title, artist: artist, duration: duration)
        guard !candidates.isEmpty else { return nil }

        let lrcs = await withTaskGroup(of: (Int, String?).self) { group in
            for (rank, isrc) in candidates.enumerated() {
                group.addTask { (rank, await lrc(isrc: isrc)) }
            }
            var results: [(rank: Int, lrc: String)] = []
            for await (rank, lrc) in group {
                if let lrc { results.append((rank, lrc)) }
            }
            return results.sorted { $0.rank < $1.rank }.map(\.lrc)
        }

        return lrcs.first(where: LRCParser.isWordSynced) ?? lrcs.first
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
    /// duration first.
    private static func matchingISRCs(title: String, artist: String, duration: TimeInterval?) async -> [String] {
        var components = URLComponents(url: baseURL.appending(path: "search.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "q", value: "\(artist) \(title)")]
        guard let url = components.url,
              let data = await LyricsService.fetchWithRetry(url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }

        let wantedTitle = normalizedTitle(title)
        let wantedArtist = normalized(artist)
        guard !wantedTitle.isEmpty else { return [] }

        let matches = response.hits.filter { hit in
            guard normalizedTitle(hit.title) == wantedTitle else { return false }
            let hitArtist = normalized(hit.artist)
            guard !hitArtist.isEmpty,
                  hitArtist.contains(wantedArtist) || wantedArtist.contains(hitArtist) else { return false }
            guard let duration, let hitDuration = hit.duration else { return true }
            return abs(hitDuration - duration) <= durationTolerance
        }

        let ranked = matches.sorted { a, b in
            guard let duration else { return false }
            return abs((a.duration ?? duration) - duration) < abs((b.duration ?? duration) - duration)
        }
        var seen = Set<String>()
        return ranked.map(\.isrc).filter { seen.insert($0).inserted }.prefix(maxCandidates).map { $0 }
    }

    private static func lrc(isrc: String) async -> String? {
        let url = baseURL.appending(path: "s/\(isrc).lrc")
        guard let data = await LyricsService.fetchWithRetry(url),
              let text = String(data: data, encoding: .utf8),
              !LRCParser.parse(text).isEmpty else { return nil }
        return text
    }

    // MARK: - Matching

    /// Drops version tags so "Song (Remastered 2011)" and "Song - Live" match "Song".
    private static func normalizedTitle(_ title: String) -> String {
        var base = title.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        if let dash = base.range(of: " - ") {
            base = String(base[..<dash.lowerBound])
        }
        return normalized(base)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
