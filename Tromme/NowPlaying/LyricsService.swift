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
    /// The lyrics currently shown, so the user can mark them as wrong.
    private(set) var current: ResolvedLyrics?
    /// How many lyrics the user has blocked for the current song.
    private(set) var blockedCount = 0
    /// Bumped each time the user blocks lyrics, to drive the confirmation haptic.
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

    /// Blocks the lyrics currently shown for this song and resolves the next match.
    func blockCurrent(track: PlexMetadata) async {
        guard let current else { return }
        BlockedLyricsStore.shared.block(current, forSong: Self.songKey(track))
        blockConfirmations += 1
        await refresh(track: track)
    }

    /// Forgets every block for this song and resolves its lyrics again.
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

        // Use track-level artist so compilations match by performer, not "Various Artists"
        let trackArtist = track.artistDisplayName
        let cacheKey = CacheKey.lyrics(title: track.title, artist: trackArtist)
        let blocked = BlockedLyricsStore.shared.fingerprints(forSong: Self.songKey(track))

        let result: ResolvedLyrics?
        // Only synced results are cached. Plain-only results may just mean a lookup failed or
        // a provider hasn't indexed the synced version yet, so they're re-resolved on the next fetch.
        if let cached = await ExternalContentCache.shared.get(ResolvedLyrics.self, forKey: cacheKey, diskTTL: Self.lyricsTTL),
           cached.value.hasSynced, Self.isAllowed(cached.value, blocked: blocked) {
            result = cached.value
        } else if let fetched = await Self.resolveRetryingOnce(track: track, artist: trackArtist, blocked: blocked) {
            // A fallback reached only because lrc.red timed out isn't cached, so the
            // next play can still find the word-synced version.
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

    /// When the vocals start and end, from synced lyrics (cached, or resolved once without retries).
    /// Auto Mix uses it to tell an instrumental intro or outro from sung parts.
    static func vocalSpan(for track: PlexMetadata) async -> (start: TimeInterval, end: TimeInterval)? {
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
        guard let first = sung.first, let last = sung.last else { return nil }
        // The closing music note row marks exactly where the last line ends.
        // Line-synced lyrics only estimate how long the last line is sung, and held notes and
        // echoes run past the final word, so leave a margin before calling the vocals done.
        let margin: TimeInterval = last.lastWordEnd != nil ? 1.5 : 4
        if let closing = parsed.last, closing.isBreak { return (first.time, closing.time + margin) }
        return (first.time, (last.lastWordEnd ?? last.time + 4) + margin)
    }

    /// An empty result right at track start is often a slow or not-yet-ready connection, not a
    /// real miss, so one more pass runs with longer deadlines before settling on "no lyrics".
    private nonisolated static func resolveRetryingOnce(track: PlexMetadata, artist: String, blocked: Set<String>) async -> (lyrics: ResolvedLyrics, isFinal: Bool)? {
        if let first = await resolve(track: track, artist: artist, blocked: blocked) { return first }
        try? await Task.sleep(for: .milliseconds(1500))
        return await resolve(track: track, artist: artist, blocked: blocked, lrcRedDeadline: 10, lrclibDeadline: 8)
    }

    // Preference order: lrc.red (word-synced, then line-synced), then LRCLIB (synced, then
    // plain). Both sources are queried
    // at once so a miss on lrc.red doesn't add its wait on top of LRCLIB's. Candidates the user
    // blocked are skipped, so the next match in this order is used instead.
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
        // lrc.red results come first, so they're final. An LRCLIB fallback reached only because
        // lrc.red timed out may be beaten next time, so it isn't.
        return (lyrics, lyrics.source == .lrcRed || !red.timedOut)
    }

    /// Blocked timed lyrics are matched exactly, so other timings of the same words stay
    /// available; plain text is also matched against blocked words.
    private nonisolated static func isAllowed(_ lyrics: ResolvedLyrics, blocked: Set<String>) -> Bool {
        if let fingerprint = lyrics.fingerprint, blocked.contains(fingerprint) { return false }
        if !lyrics.hasSynced, let textFingerprint = lyrics.textFingerprint, blocked.contains(textFingerprint) { return false }
        return true
    }

    /// How long each source gets before the next one is tried.
    private nonisolated static let sourceTimeout: TimeInterval = 2
    /// lrc.red needs a search plus an LRC fetch per matching release before it knows whether
    /// any are word-synced, so it gets longer. LRCLIB runs alongside, so this only adds wait
    /// when lrc.red itself is slow.
    private nonisolated static let lrcRedTimeout: TimeInterval = 4

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

    // Fetches every LRCLIB match for the track and returns its candidates in preference order:
    // synced lyrics within the duration tolerance (closest duration first), then each distinct
    // plain text (closest duration first), since untimed text doesn't depend on the recording.
    // Uses the fuzzy search endpoint (not /api/get) so name/album mismatches don't hide a synced record.
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

    // Retries transient failures (timeouts, dropped connections, 5xx) so a momentary
    // network hiccup doesn't get treated the same as a confirmed "no lyrics" 404 and cause
    // resolve() to settle prematurely on a worse (e.g. plain-only) fallback result. Other 4xx
    // answers (429 included, a retry seconds later hits the same limit) are final, and a cancelled lookup (deadline hit) stops instead of re-sending.
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

    /// How early a word-synced line comes into focus before its first word, so it
    /// is settled by the time the words start animating.
    private static let focusLeadTime: TimeInterval = 1.0

    func currentLineIndex(at time: TimeInterval) -> Int {
        lines.indices.last(where: { focusTime(of: $0) <= time }) ?? 0
    }

    /// When a line takes focus. Word-synced lines get up to `focusLeadTime` of lead,
    /// limited to the silence after the previous line's last word, so tightly timed
    /// lines focus as the previous one finishes (or at their own start if they overlap).
    private func focusTime(of index: Int) -> TimeInterval {
        let line = lines[index]
        guard index > 0, !line.isBreak, !line.words.isEmpty else { return line.time }
        let previous = lines[index - 1]
        // A music break row starts where the previous line ends, so the gap is all silence.
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
