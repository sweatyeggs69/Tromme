import Foundation
import Observation

struct LyricsLine: Identifiable, Sendable {
    let id = UUID()
    let time: TimeInterval
    let text: String
    /// Per-word timing when the lyrics are word-synced; empty for line-synced lyrics.
    var words: [LyricsWord] = []
}

struct LyricsWord: Sendable {
    let time: TimeInterval
    let endTime: TimeInterval
    /// Includes any trailing space, so joining a line's words rebuilds its text.
    let text: String
}

@MainActor
@Observable
final class LyricsService {
    private(set) var lines: [LyricsLine] = []
    private(set) var plainLyrics: String?
    private(set) var isLoading = false
    private(set) var hasSynced = false
    private(set) var hasWordSync = false
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
        await ExternalContentCache.shared.remove(forKey: cacheKey)
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
        hasWordSync = false
        hasLyrics = false

        // Use track-level artist so compilations match by performer, not "Various Artists"
        let trackArtist = track.artistDisplayName
        let cacheKey = CacheKey.lyrics(title: track.title, artist: trackArtist)

        let result: ResolvedLyrics?
        // Only synced results are cached. Plain-only results may just mean a lookup failed or
        // a provider hasn't indexed the synced version yet, so they're re-resolved on the next fetch.
        if let cached = await ExternalContentCache.shared.get(ResolvedLyrics.self, forKey: cacheKey, diskTTL: Self.lyricsTTL),
           cached.value.hasSynced {
            result = cached.value
        } else if let fetched = await Self.resolve(track: track, artist: trackArtist) {
            if fetched.hasSynced {
                await ExternalContentCache.shared.set(fetched, forKey: cacheKey)
            }
            result = fetched
        } else {
            result = nil
        }

        guard activeRequestID == requestID else { return }
        if let result { apply(result) }
        isLoading = false
    }

    // Fallback chain: word-synced from lrc.red, then line-synced from lrc.red, then synced
    // from LRCLIB, then plain from LRCLIB.
    private nonisolated static func resolve(track: PlexMetadata, artist: String) async -> ResolvedLyrics? {
        let seconds = track.duration.map { Double($0) / 1000 }
        if let lrc = await LrcRedLyricsProvider.syncedLyrics(title: track.title, artist: artist, duration: seconds) {
            return ResolvedLyrics(syncedLyrics: lrc, plainLyrics: nil)
        }
        guard let lrclib = await resolveLRCLIB(track: track, artist: artist) else { return nil }
        return ResolvedLyrics(syncedLyrics: lrclib.syncedLyrics, plainLyrics: lrclib.plainLyrics)
    }

    /// Synced lyrics from a recording whose length differs by more than this
    /// are likely a different edit or master, so their timing would drift.
    /// Matches the tolerance LRCLIB's own /api/get uses.
    nonisolated static let syncedDurationTolerance: TimeInterval = 2

    // Fetches every LRCLIB match for the track and prefers synced lyrics within the duration
    // tolerance, choosing the closest duration among them. Otherwise falls back to the closest
    // match's plain lyrics, since untimed text doesn't depend on the recording.
    // Uses the fuzzy search endpoint (not /api/get) so name/album mismatches don't hide a synced record.
    private nonisolated static func resolveLRCLIB(track: PlexMetadata, artist: String) async -> LRCLIBResponse? {
        var results = await search([.init(name: "track_name", value: track.title),
                                    .init(name: "artist_name", value: artist)])
        if results.isEmpty {
            results = await search([.init(name: "q", value: "\(artist) \(track.title)")])
        }

        guard let seconds = track.duration.map({ Double($0) / 1000 }) else {
            return results.first(where: \.hasSynced) ?? results.first
        }
        let offset = { (result: LRCLIBResponse) in abs((result.duration ?? seconds) - seconds) }
        let byDuration = results.sorted { offset($0) < offset($1) }

        if let synced = byDuration.first(where: { $0.hasSynced && offset($0) <= syncedDurationTolerance }) {
            return synced
        }
        guard let closest = byDuration.first(where: { $0.plainLyrics?.isEmpty == false }) else { return nil }
        return LRCLIBResponse(syncedLyrics: nil, plainLyrics: closest.plainLyrics, duration: closest.duration)
    }

    private nonisolated static func search(_ query: [URLQueryItem]) async -> [LRCLIBResponse] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = query
        guard let url = components.url, let data = await fetchWithRetry(url) else { return [] }
        return (try? JSONDecoder().decode([LRCLIBResponse].self, from: data)) ?? []
    }

    // Retries transient failures (timeouts, dropped connections, 429/5xx) so a momentary
    // network hiccup doesn't get treated the same as a confirmed "no lyrics" 404 and cause
    // resolve() to settle prematurely on a worse (e.g. plain-only) fallback result.
    nonisolated static func fetchWithRetry(_ url: URL, retries: Int = 2) async -> Data? {
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

    private func apply(_ response: ResolvedLyrics) {
        if let synced = response.syncedLyrics, !synced.isEmpty {
            lines = LRCParser.parse(synced)
            hasSynced = !lines.isEmpty
            hasWordSync = lines.contains { !$0.words.isEmpty }
            hasLyrics = hasSynced
        }
        if !hasSynced, let plain = response.plainLyrics, !plain.isEmpty {
            plainLyrics = plain
            hasLyrics = true
        }
    }

    /// Line-synced lines activate slightly ahead of their timestamp so the
    /// active lyric is already in place when it's sung.
    private static let lineSyncedLeadTime: TimeInterval = 0.15

    /// Word-synced lines activate up to this far ahead of their first word so
    /// the new line has settled before its wipe starts.
    private static let wordSyncedLeadTime: TimeInterval = 1

    func currentLineIndex(at time: TimeInterval) -> Int {
        lines.indices.last(where: { activationTime(of: $0) <= time }) ?? 0
    }

    /// Word-synced lines only advance early into the gap after the previous
    /// line's last word, so tight verses aren't cut off mid-line.
    private func activationTime(of index: Int) -> TimeInterval {
        let line = lines[index]
        guard hasWordSync else { return line.time - Self.lineSyncedLeadTime }
        let early = line.time - Self.wordSyncedLeadTime
        guard index > 0, let previousEnd = lines[index - 1].words.last?.endTime else { return early }
        return min(max(early, previousEnd), line.time)
    }

    private static func looksInstrumental(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z\\s]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ") == "instrumental"
    }
}

// MARK: - Resolved Lyrics

/// What the fallback chain settled on: a timed LRC (word- or line-synced) or plain text.
struct ResolvedLyrics: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?

    var hasSynced: Bool { syncedLyrics?.isEmpty == false }
}

// MARK: - lrclib Response

struct LRCLIBResponse: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?

    var hasSynced: Bool { syncedLyrics?.isEmpty == false }
}
