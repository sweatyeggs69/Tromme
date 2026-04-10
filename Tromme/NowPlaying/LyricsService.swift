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

        let cacheKey = CacheKey.lyrics(title: track.title, artist: track.artistName)

        // Check cache first
        if let cached = await LibraryCache.shared.get(LRCLIBResponse.self, forKey: cacheKey, diskTTL: Self.lyricsTTL) {
            guard isCurrentRequest(requestID) else { return }
            apply(cached.value)
            completeIfCurrent(requestID)
            return
        }

        // Fetch from lrclib.net
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artistName),
        ]
        if let album = track.parentTitle {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        if let ms = track.duration {
            queryItems.append(URLQueryItem(name: "duration", value: "\(ms / 1000)"))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            completeIfCurrent(requestID)
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                completeIfCurrent(requestID)
                return
            }
            let decoded = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
            await LibraryCache.shared.set(decoded, forKey: cacheKey)
            guard isCurrentRequest(requestID) else { return }
            apply(decoded)
        } catch {
            // Lyrics not available — leave empty
        }

        completeIfCurrent(requestID)
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
}

// MARK: - lrclib Response

struct LRCLIBResponse: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
}
