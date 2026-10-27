import Foundation

struct LastFMService: Sendable {

    /// Returns the subset of `albumTrackTitles` that appear in the artist's all-time top 10
    /// on Last.fm. Caching happens at api.tromme.app and in URLSession (Cache-Control).
    static func fetchPopularTracks(
        artist: String,
        albumTrackTitles: [String]
    ) async -> Set<String> {
        guard !artist.isEmpty, !albumTrackTitles.isEmpty else { return [] }

        guard let topTen = try? await fetchTopTenNormalized(artist: artist) else { return [] }

        let topTenSet = Set(topTen)
        return Set(albumTrackTitles.filter { topTenSet.contains(normalized($0)) })
    }

    // MARK: - Network

    private static func fetchTopTenNormalized(artist: String) async throws -> [String] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.tromme.app"
        components.path = "/lastfm/top-tracks"
        components.queryItems = [URLQueryItem(name: "artist", value: artist)]

        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(LastFMTopTracksResponse.self, from: data)
        return (decoded.toptracks?.track ?? []).map { normalized($0.name) }
    }

    // MARK: - Normalization

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
