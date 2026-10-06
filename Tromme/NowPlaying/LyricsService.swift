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
            // A fallback reached only because lrc.red timed out isn't cached, so the
            // next play can still find the word-synced version.
            if fetched.lyrics.hasSynced, fetched.isFinal {
                await ExternalContentCache.shared.set(fetched.lyrics, forKey: cacheKey)
            }
            result = fetched.lyrics
        } else {
            result = nil
        }

        guard activeRequestID == requestID else { return }
        if let result { apply(result) }
        isLoading = false
    }

    // Fallback chain: word-synced from lrc.red, then line-synced from lrc.red, then synced
    // from LRCLIB, then plain from LRCLIB.
    private nonisolated static func resolve(track: PlexMetadata, artist: String) async -> (lyrics: ResolvedLyrics, isFinal: Bool)? {
        let title = track.title
        let seconds = track.duration.map { Double($0) / 1000 }

        let lrcRed = await withDeadline(sourceTimeout) {
            await LrcRedLyricsProvider.syncedLyrics(title: title, artist: artist, duration: seconds)
        }
        if let lrc = lrcRed.value {
            return (ResolvedLyrics(syncedLyrics: lrc, plainLyrics: nil, duration: nil), true)
        }

        let lrclib = await withDeadline(sourceTimeout) {
            await resolveLRCLIB(title: title, artist: artist, seconds: seconds)
        }
        guard let lyrics = lrclib.value else { return nil }
        return (lyrics, !lrcRed.timedOut)
    }

    /// How long each source gets before the next one is tried.
    private nonisolated static let sourceTimeout: TimeInterval = 2

    /// Runs `operation`, giving up on it after `seconds`.
    private nonisolated static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T?
    ) async -> (value: T?, timedOut: Bool) {
        await withTaskGroup(of: (T?, Bool).self) { group in
            group.addTask { (await operation(), false) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return (nil, true)
            }
            let first = await group.next() ?? (nil, true)
            group.cancelAll()
            return (first.0, first.1)
        }
    }

    /// Synced lyrics from a recording whose length differs by more than this
    /// are likely a different edit or master, so their timing would drift.
    /// Matches the tolerance LRCLIB's own /api/get uses.
    nonisolated static let syncedDurationTolerance: TimeInterval = 2

    // Fetches every LRCLIB match for the track and prefers synced lyrics within the duration
    // tolerance, choosing the closest duration among them. Otherwise falls back to the closest
    // match's plain lyrics, since untimed text doesn't depend on the recording.
    // Uses the fuzzy search endpoint (not /api/get) so name/album mismatches don't hide a synced record.
    private nonisolated static func resolveLRCLIB(title: String, artist: String, seconds: Double?) async -> ResolvedLyrics? {
        var results = await search([.init(name: "track_name", value: title),
                                    .init(name: "artist_name", value: artist)])
        if results.isEmpty {
            results = await search([.init(name: "q", value: "\(artist) \(title)")])
        }

        guard let seconds else {
            return results.first(where: \.hasSynced) ?? results.first
        }
        let offset = { (result: ResolvedLyrics) in abs((result.duration ?? seconds) - seconds) }
        let byDuration = results.sorted { offset($0) < offset($1) }

        if let synced = byDuration.first(where: { $0.hasSynced && offset($0) <= syncedDurationTolerance }) {
            return synced
        }
        guard let closest = byDuration.first(where: { $0.plainLyrics?.isEmpty == false }) else { return nil }
        return ResolvedLyrics(syncedLyrics: nil, plainLyrics: closest.plainLyrics, duration: closest.duration)
    }

    private nonisolated static func search(_ query: [URLQueryItem]) async -> [ResolvedLyrics] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = query
        guard let url = components.url, let data = await fetchWithRetry(url) else { return [] }
        return (try? JSONDecoder().decode([ResolvedLyrics].self, from: data)) ?? []
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
            hasLyrics = hasSynced
        }
        if !hasSynced, let plain = response.plainLyrics, !plain.isEmpty {
            plainLyrics = plain
            hasLyrics = true
        }
    }

    func currentLineIndex(at time: TimeInterval) -> Int {
        lines.lastIndex(where: { $0.time <= time }) ?? 0
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
/// Also the shape of an LRCLIB search result, whose `duration` (seconds) is used for matching.
struct ResolvedLyrics: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?

    var hasSynced: Bool { syncedLyrics?.isEmpty == false }
}
