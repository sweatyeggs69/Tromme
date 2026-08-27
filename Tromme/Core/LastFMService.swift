import Foundation

struct LastFMService: Sendable {

    private static let apiKey = "b78cca3f0e48b50bbef9ce3b357a5bb3"

    /// Returns the subset of `albumTrackTitles` that appear in the artist's all-time top 10
    /// on Last.fm. Matching is done on normalized names (case-insensitive, remaster/feat. suffixes stripped).
    static func fetchPopularTracks(
        artist: String,
        albumTrackTitles: [String]
    ) async -> Set<String> {
        guard !artist.isEmpty, !albumTrackTitles.isEmpty else { return [] }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "ws.audioscrobbler.com"
        components.path = "/2.0/"
        components.queryItems = [
            URLQueryItem(name: "method", value: "artist.gettoptracks"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "autocorrect", value: "1")
        ]

        guard let url = components.url else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

            let decoded = try JSONDecoder().decode(LastFMTopTracksResponse.self, from: data)
            let topTen = Set((decoded.toptracks?.track ?? []).map { normalized($0.name) })
            guard !topTen.isEmpty else { return [] }

            return Set(albumTrackTitles.filter { topTen.contains(normalized($0)) })
        } catch {
            return []
        }
    }

    private static func normalized(_ name: String) -> String {
        var s = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: " - ") {
            s = String(s[..<range.lowerBound])
        }
        while let range = s.range(of: #"\s*\([^)]*\)$"#, options: .regularExpression) {
            s = String(s[..<range.lowerBound])
        }
        for marker in [" feat.", " ft."] {
            if let range = s.range(of: marker) {
                s = String(s[..<range.lowerBound])
            }
        }
        s = s
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Response models

private struct LastFMTopTracksResponse: Decodable {
    let toptracks: LastFMTopTracks?
}

private struct LastFMTopTracks: Decodable {
    let track: [LastFMTrack]?
}

private struct LastFMTrack: Decodable {
    let name: String
}
