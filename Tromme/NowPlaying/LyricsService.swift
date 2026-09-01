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

    private static let lyricsTTL: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    var isInstrumental: Bool {
        guard let plainLyrics else { return false }
        return Self.looksInstrumental(plainLyrics)
    }

    /// Discards the cached lyrics for this track and re-fetches from the network.
    func refresh(track: PlexMetadata) async {
        let cacheKey = CacheKey.lyrics(title: track.title, artist: track.artistDisplayName)
        await LibraryCache.shared.remove(forKey: cacheKey)
        inFlightTrackKey = nil
        await fetch(track: track)
    }

    func fetch(track: PlexMetadata) async {
        if isLoading, inFlightTrackKey == track.ratingKey {
            return
        }

        let requestID = UUID()
        activeRequestID = requestID
        inFlightTrackKey = track.ratingKey

        isLoading = true
        lines = []
        plainLyrics = nil
        hasSynced = false
        hasLyrics = false

        // Use track-level artist (Plex originalTitle) so compilations/soundtracks match by performer, not "Various Artists"
        let trackArtist = track.artistDisplayName
        let cacheKey = CacheKey.lyrics(title: track.title, artist: trackArtist)

        // Check cache first
        if let cached = await LibraryCache.shared.get(LRCLIBResponse.self, forKey: cacheKey, diskTTL: Self.lyricsTTL) {
            guard isCurrentRequest(requestID) else { return }
            apply(cached.value)
            completeIfCurrent(requestID)
            return
        }

        // Attempt 1: query with track-level artist
        if let decoded = await fetchFromLRCLib(title: track.title, artist: trackArtist, album: track.parentTitle, duration: track.duration) {
            await LibraryCache.shared.set(decoded, forKey: cacheKey)
            guard isCurrentRequest(requestID) else { return }
            apply(decoded)
            completeIfCurrent(requestID)
            return
        }

        // Attempt 2: for soundtracks/compilations where the track artist differs from the album artist,
        // retry without an artist filter so title + album + duration can still find a match.
        if trackArtist != track.artistName {
            if let decoded = await fetchFromLRCLib(title: track.title, artist: nil, album: track.parentTitle, duration: track.duration) {
                await LibraryCache.shared.set(decoded, forKey: cacheKey)
                guard isCurrentRequest(requestID) else { return }
                apply(decoded)
            }
        }

        completeIfCurrent(requestID)
    }

    private func fetchFromLRCLib(title: String, artist: String?, album: String?, duration: Int?) async -> LRCLIBResponse? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems = [URLQueryItem(name: "track_name", value: title)]
        if let artist { queryItems.append(URLQueryItem(name: "artist_name", value: artist)) }
        if let album { queryItems.append(URLQueryItem(name: "album_name", value: album)) }
        if let ms = duration { queryItems.append(URLQueryItem(name: "duration", value: "\(ms / 1000)")) }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(LRCLIBResponse.self, from: data)
        } catch {
            return nil
        }
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
        var result = 0
        for (i, line) in lines.enumerated() {
            if line.time <= time { result = i } else { break }
        }
        return result
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

            // Parse MM:SS.xx
            let parts = timestamp.components(separatedBy: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { continue }

            result.append(LyricsLine(time: minutes * 60 + seconds, text: text))
        }

        return result.sorted { $0.time < $1.time }
    }

    private func isCurrentRequest(_ requestID: UUID) -> Bool {
        activeRequestID == requestID
    }

    private func completeIfCurrent(_ requestID: UUID) {
        guard isCurrentRequest(requestID) else { return }
        isLoading = false
    }

    private static func looksInstrumental(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z\\s]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized == "instrumental"
    }
}

// MARK: - lrclib Response

struct LRCLIBResponse: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
}
