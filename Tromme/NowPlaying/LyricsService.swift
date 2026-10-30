import Foundation
import Observation

@MainActor
@Observable
final class LyricsService {
    private(set) var lines: [LyricsLine] = []
    private(set) var plainLyrics: String?
    private(set) var isLoading = false
    private(set) var hasSynced = false
    private(set) var hasLyrics = false
    private(set) var current: ResolvedLyrics?
    private(set) var blockedCount = 0
    private(set) var blockConfirmations = 0

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

    func blockCurrent(track: PlexMetadata) async {
        guard let current else { return }
        BlockedLyricsStore.shared.block(current, forSong: Self.songKey(track))
        blockConfirmations += 1
        await refresh(track: track)
    }

    func unblockAll(track: PlexMetadata) async {
        BlockedLyricsStore.shared.clear(forSong: Self.songKey(track))
        await refresh(track: track)
    }

    private static func songKey(_ track: PlexMetadata) -> String {
        BlockedLyricsStore.songKey(title: track.title, artist: track.artistDisplayName)
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
        current = nil
        blockedCount = BlockedLyricsStore.shared.blockCount(forSong: Self.songKey(track))

        let trackArtist = track.artistDisplayName
        let cacheKey = CacheKey.lyrics(title: track.title, artist: trackArtist)
        let blocked = BlockedLyricsStore.shared.fingerprints(forSong: Self.songKey(track))

        let result: ResolvedLyrics?
        if let cached = await ExternalContentCache.shared.get(ResolvedLyrics.self, forKey: cacheKey, diskTTL: Self.lyricsTTL),
           cached.value.hasSynced, Self.isAllowed(cached.value, blocked: blocked) {
            result = cached.value
        } else if let fetched = await Self.resolveRetryingOnce(track: track, artist: trackArtist, blocked: blocked) {
            if fetched.lyrics.hasSynced, fetched.isFinal {
                await ExternalContentCache.shared.set(fetched.lyrics, forKey: cacheKey)
            }
            result = fetched.lyrics
        } else {
            result = nil
            #if DEBUG
            print("[Lyrics] no lyrics resolved for \(track.title) / \(trackArtist) (ratingKey \(track.ratingKey))")
            #endif
        }

        guard activeRequestID == requestID else { return }
        if let result { apply(result, trackDuration: track.duration.map { Double($0) / 1000 }) }
        isLoading = false
    }

    static func vocalSpan(for track: PlexMetadata) async -> (start: TimeInterval, end: TimeInterval, endIsMarked: Bool)? {
        let artist = track.artistDisplayName
        let cacheKey = CacheKey.lyrics(title: track.title, artist: artist)
        let blocked = BlockedLyricsStore.shared.fingerprints(forSong: songKey(track))
        let lyrics: ResolvedLyrics
        if let cached = await ExternalContentCache.shared.get(ResolvedLyrics.self, forKey: cacheKey, diskTTL: lyricsTTL),
           cached.value.hasSynced, isAllowed(cached.value, blocked: blocked) {
            lyrics = cached.value
        } else if let fetched = await resolve(track: track, artist: artist, blocked: blocked), fetched.lyrics.hasSynced {
            if fetched.isFinal { await ExternalContentCache.shared.set(fetched.lyrics, forKey: cacheKey) }
            lyrics = fetched.lyrics
        } else {
            return nil
        }
        guard let synced = lyrics.syncedLyrics else { return nil }
        let parsed = LRCParser.parse(synced, trackDuration: track.duration.map { Double($0) / 1000 })
        let sung = parsed.filter { !$0.isBreak }
        guard var first = sung.first, let last = sung.last else { return nil }
        if sung.count > 2, first.time < 15,
           let index = parsed.firstIndex(where: { !$0.isBreak }),
           parsed.indices.contains(index + 1), parsed[index + 1].isBreak {
            first = sung[1]
        }
        let closing = parsed.last.flatMap { $0.isBreak ? $0.time : nil }
        let end = closing ?? last.lastWordEnd ?? last.time + 4
        return (first.time, end, closing != nil)
    }

    private nonisolated static func resolveRetryingOnce(track: PlexMetadata, artist: String, blocked: Set<String>) async -> (lyrics: ResolvedLyrics, isFinal: Bool)? {
        if let first = await resolve(track: track, artist: artist, blocked: blocked) { return first }
        try? await Task.sleep(for: .milliseconds(1500))
        return await resolve(track: track, artist: artist, blocked: blocked, lrcRedDeadline: 10, lrclibDeadline: 8)
    }

    private nonisolated static func resolve(track: PlexMetadata, artist: String, blocked: Set<String>,
                                          lrcRedDeadline: TimeInterval = lrcRedTimeout,
                                          lrclibDeadline: TimeInterval = sourceTimeout) async -> (lyrics: ResolvedLyrics, isFinal: Bool)? {
        let title = track.title
        let seconds = track.duration.map { Double($0) / 1000 }

        async let lrcRed = withDeadline(lrcRedDeadline) {
            await LrcRedLyricsProvider.timedLyrics(title: title, artist: artist, duration: seconds)
        }
        async let lrclib = withDeadline(lrclibDeadline) {
            await resolveLRCLIB(title: title, artist: artist, seconds: seconds)
        }

        let red = await lrcRed
        let timed = red.value ?? LrcRedLyricsProvider.TimedLyrics()
        let lrcRedLyrics = { (lrc: String) in
            ResolvedLyrics(syncedLyrics: lrc, plainLyrics: nil, duration: nil, source: .lrcRed)
        }
        let lib = await lrclib
        let lrclibResults = (lib.value ?? []).map { result -> ResolvedLyrics in
            var result = result
            result.source = .lrclib
            return result
        }

        let candidates: [ResolvedLyrics] = timed.wordSynced.map(lrcRedLyrics)
            + timed.lineSynced.map(lrcRedLyrics)
            + lrclibResults
        guard let lyrics = candidates.first(where: { isAllowed($0, blocked: blocked) }) else { return nil }
        return (lyrics, lyrics.source == .lrcRed || !red.timedOut)
    }

    private nonisolated static func isAllowed(_ lyrics: ResolvedLyrics, blocked: Set<String>) -> Bool {
        if let fingerprint = lyrics.fingerprint, blocked.contains(fingerprint) { return false }
        if !lyrics.hasSynced, let textFingerprint = lyrics.textFingerprint, blocked.contains(textFingerprint) { return false }
        return true
    }

    private nonisolated static let sourceTimeout: TimeInterval = 2
    private nonisolated static let lrcRedTimeout: TimeInterval = 4

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

    nonisolated static let syncedDurationTolerance: TimeInterval = 2

    private nonisolated static func resolveLRCLIB(title: String, artist: String, seconds: Double?) async -> [ResolvedLyrics] {
        var results = await search([.init(name: "track_name", value: title),
                                    .init(name: "artist_name", value: artist)])
        if results.isEmpty {
            results = await search([.init(name: "q", value: "\(artist) \(title)")])
        }

        let ordered: [ResolvedLyrics]
        let synced: [ResolvedLyrics]
        if let seconds {
            let offset = { (result: ResolvedLyrics) in abs((result.duration ?? seconds) - seconds) }
            ordered = results.sorted { offset($0) < offset($1) }
            synced = ordered.filter { $0.hasSynced && offset($0) <= syncedDurationTolerance }
        } else {
            ordered = results
            synced = results.filter(\.hasSynced)
        }

        var seenPlain = Set<String>()
        let plain = ordered.compactMap { result -> ResolvedLyrics? in
            guard let text = result.plainLyrics, !text.isEmpty, seenPlain.insert(text).inserted else { return nil }
            return ResolvedLyrics(syncedLyrics: nil, plainLyrics: text, duration: result.duration, source: .lrclib)
        }
        return synced + plain
    }

    private nonisolated static func search(_ query: [URLQueryItem]) async -> [ResolvedLyrics] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = query
        guard let url = components.url, let data = await fetchWithRetry(url) else { return [] }
        return (try? JSONDecoder().decode([ResolvedLyrics].self, from: data)) ?? []
    }

    nonisolated static func fetchWithRetry(_ url: URL, retries: Int = 2) async -> Data? {
        for attempt in 0...retries {
            if Task.isCancelled { return nil }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse {
                if http.statusCode == 200 { return data }
                #if DEBUG
                print("[Lyrics] \(http.statusCode) from \(url.host() ?? "?"), attempt \(attempt + 1)")
                #endif
                if !(500...599).contains(http.statusCode) { return nil }
            }
            if attempt < retries {
                try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
            }
        }
        return nil
    }

    private func apply(_ response: ResolvedLyrics, trackDuration: TimeInterval?) {
        current = response
        if let synced = response.syncedLyrics, !synced.isEmpty {
            lines = LRCParser.parse(synced, trackDuration: trackDuration)
            hasSynced = !lines.isEmpty
            hasLyrics = hasSynced
        }
        if !hasSynced, let plain = response.plainLyrics, !plain.isEmpty {
            plainLyrics = plain
            hasLyrics = true
        }
    }

    private static let focusLeadTime: TimeInterval = 1.0

    func currentLineIndex(at time: TimeInterval) -> Int {
        lines.indices.last(where: { focusTime(of: $0) <= time }) ?? 0
    }

    private func focusTime(of index: Int) -> TimeInterval {
        let line = lines[index]
        guard index > 0, !line.isBreak, !line.words.isEmpty else { return line.time }
        let previous = lines[index - 1]
        guard let previousEnd = previous.isBreak ? previous.time : previous.lastWordEnd else { return line.time }
        let lead = min(Self.focusLeadTime, max(0, line.time - previousEnd))
        return max(line.time - lead, previous.time)
    }

    private static func looksInstrumental(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z\\s]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ") == "instrumental"
    }
}
