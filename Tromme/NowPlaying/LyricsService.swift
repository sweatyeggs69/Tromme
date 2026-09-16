import Foundation
import Observation

struct LyricsLine: Identifiable, Sendable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

@MainActor
@Observable
final class LyricsService {
    private(set) var lines: [LyricsLine] = []
    private(set) var plainLyrics: String?
    private(set) var isLoading = false
    private(set) var hasSynced = false
    private(set) var hasLyrics = false

    private var activeRequestID: UUID?
    private var inFlightTrackKey: String?

    private static let lyricsTTL: TimeInterval = 7 * 24 * 60 * 60

    var isInstrumental: Bool {
        guard let plainLyrics else { return false }
        return Self.looksInstrumental(plainLyrics)
    }

    func refresh(track: PlexMetadata) async {
        let cacheKey = CacheKey.lyrics(title: track.title, artist: track.artistDisplayName)
        await LibraryCache.shared.remove(forKey: cacheKey)
        inFlightTrackKey = nil
        await fetch(track: track)
    }

    func fetch(track: PlexMetadata) async {
        if isLoading, inFlightTrackKey == track.ratingKey { return }

        let requestID = UUID()
        activeRequestID = requestID
        inFlightTrackKey = track.ratingKey
        isLoading = true
        lines = []
        plainLyrics = nil
        hasSynced = false
        hasLyrics = false

        // Use track-level artist so compilations match by performer, not "Various Artists"
        let trackArtist = track.artistDisplayName
        let cacheKey = CacheKey.lyrics(title: track.title, artist: trackArtist)

        let result: LRCLIBResponse?
        if let cached = await LibraryCache.shared.get(LRCLIBResponse.self, forKey: cacheKey, diskTTL: Self.lyricsTTL) {
            result = cached.value
        } else if let fetched = await Self.resolve(track: track, artist: trackArtist) {
            await LibraryCache.shared.set(fetched, forKey: cacheKey)
            result = fetched
        } else {
            result = nil
        }

        guard activeRequestID == requestID else { return }
        if let result { apply(result) }
        isLoading = false
    }

    // Candidate lookups, most-trustworthy first. Each tries to resolve the same track under a
    // different name/album guess — needed because /api/get requires an exact metadata match,
    // and compilations/soundtracks often have mismatched artist or album names in Plex vs LRCLIB.
    private nonisolated static func lookups(track: PlexMetadata, artist: String) -> [@Sendable () async -> LRCLIBResponse?] {
        let title = track.title
        let dur = track.duration
        var lookups: [@Sendable () async -> LRCLIBResponse?] = [
            // No album — avoids false negatives from mismatched release names (e.g. "Song - Single" vs album)
            { await get(title: title, artist: artist, album: nil, duration: dur) }
        ]
        if let album = track.parentTitle {
            if artist != track.artistName {
                // Compilations: drop artist, keep album
                lookups.append { await get(title: title, artist: nil, album: album, duration: dur) }
            }
            // Album as last-resort disambiguator for /api/get
            lookups.append { await get(title: title, artist: artist, album: album, duration: dur) }
        }
        // Fuzzy search — handles artist name variations and metadata that exact matching rejects
        lookups.append { await search(title: title, artist: artist, duration: dur) }
        return lookups
    }

    // Runs all candidate lookups concurrently, then picks the highest-priority synced hit,
    // falling back to the highest-priority plain hit if none are synced.
    private nonisolated static func resolve(track: PlexMetadata, artist: String) async -> LRCLIBResponse? {
        let lookups = lookups(track: track, artist: artist)
        let results = await withTaskGroup(of: (Int, LRCLIBResponse?).self) { group in
            for (index, lookup) in lookups.enumerated() {
                group.addTask { (index, await lookup()) }
            }
            var ordered = [LRCLIBResponse?](repeating: nil, count: lookups.count)
            for await (index, result) in group { ordered[index] = result }
            return ordered.compactMap { $0 }
        }

        if let synced = results.first(where: { $0.syncedLyrics?.isEmpty == false }) { return synced }
        return results.first
    }

    private nonisolated static func get(title: String, artist: String?, album: String?, duration: Int?) async -> LRCLIBResponse? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let artist { items.append(.init(name: "artist_name", value: artist)) }
        if let album  { items.append(.init(name: "album_name",  value: album))  }
        if let ms = duration { items.append(.init(name: "duration", value: "\(ms / 1000)")) }
        components.queryItems = items
        guard let url = components.url, let data = await lrclibFetch(url) else { return nil }
        return try? JSONDecoder().decode(LRCLIBResponse.self, from: data)
    }

    private nonisolated static func search(title: String, artist: String, duration: Int?) async -> LRCLIBResponse? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist)
        ]
        guard let url = components.url, let data = await lrclibFetch(url) else { return nil }
        let results = (try? JSONDecoder().decode([LRCLIBResponse].self, from: data)) ?? []
        guard !results.isEmpty else { return nil }

        let trackSeconds = duration.map { Double($0) / 1000 }
        let withSynced = results.filter { $0.syncedLyrics?.isEmpty == false }
        let pool = withSynced.isEmpty ? results : withSynced

        guard let trackSeconds else { return pool.first }
        return pool.min(by: {
            abs(($0.duration ?? trackSeconds) - trackSeconds) <
            abs(($1.duration ?? trackSeconds) - trackSeconds)
        })
    }

    // Retries transient failures (timeouts, dropped connections, 429/5xx) so a momentary
    // network hiccup doesn't get treated the same as a confirmed "no lyrics" 404 and cause
    // resolve() to settle prematurely on a worse (e.g. plain-only) fallback result.
    private nonisolated static func lrclibFetch(_ url: URL, retries: Int = 2) async -> Data? {
        for attempt in 0...retries {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse {
                if http.statusCode == 200 { return data }
                if http.statusCode == 404 { return nil }
            }
            if attempt < retries {
                try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
            }
        }
        return nil
    }

    private func apply(_ response: LRCLIBResponse) {
        if let synced = response.syncedLyrics, !synced.isEmpty {
            lines = parseLRC(synced)
            hasSynced = !lines.isEmpty
            hasLyrics = hasSynced
        } else if let plain = response.plainLyrics, !plain.isEmpty {
            plainLyrics = plain
            hasLyrics = true
        }
    }

    func currentLineIndex(at time: TimeInterval) -> Int {
        lines.lastIndex(where: { $0.time <= time }) ?? 0
    }

    // MARK: - LRC Parsing

    private func parseLRC(_ lrc: String) -> [LyricsLine] {
        var result: [LyricsLine] = []
        for rawLine in lrc.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["),
                  let closeBracket = line.firstIndex(of: "]") else { continue }
            let timestamp = String(line[line.index(after: line.startIndex)..<closeBracket])
            let text = String(line[line.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let parts = timestamp.components(separatedBy: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { continue }
            result.append(LyricsLine(time: minutes * 60 + seconds, text: text))
        }
        return result.sorted { $0.time < $1.time }
    }

    private static func looksInstrumental(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z\\s]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ") == "instrumental"
    }
}

// MARK: - lrclib Response

struct LRCLIBResponse: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?
}
