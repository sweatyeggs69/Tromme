import Foundation

/// Finds an artist's logo on fanart.tv. The artist's MusicBrainz id comes from the Plex
/// `Guid` tags when present, else from a MusicBrainz name search. The resulting URL is
/// cached by `ExternalContentCache`, and the image itself by `ImageCache` (both on disk),
/// so a logo is only ever looked up and downloaded once.
enum ArtistLogoService {
    static func logoURL(for artist: PlexMetadata) async -> URL? {
        guard let apiKey = FanartSecret.apiKey else { return nil }
        let name = artist.title
        let plexID = artist.musicBrainzArtistID
        let key = CacheKey.artistLogo(mbid: plexID, name: name)
        let record = try? await ExternalContentCache.shared.cachedFetch(
            ArtistLogoRecord.self,
            forKey: key,
            policy: .artistLogo
        ) {
            try await fetchRecord(name: name, plexID: plexID, apiKey: apiKey)
        }
        return record?.logoURL.flatMap(URL.init(string:))
    }

    // MARK: - Network

    private static func fetchRecord(name: String, plexID: String?, apiKey: String) async throws -> ArtistLogoRecord {
        let mbid: String?
        if let plexID {
            mbid = plexID
        } else {
            mbid = try await musicBrainzID(forArtist: name)
        }
        guard let mbid else { return ArtistLogoRecord(logoURL: nil) }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "webservice.fanart.tv"
        components.path = "/v3/music/\(mbid)"
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return ArtistLogoRecord(logoURL: nil) }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }

        let decoded = try JSONDecoder().decode(FanartMusicResponse.self, from: data)
        let hd = candidates(in: decoded.hdmusiclogo)
        let urls = hd.isEmpty ? candidates(in: decoded.musiclogo) : hd
        return ArtistLogoRecord(logoURL: await lightest(of: urls)?.absoluteString)
    }

    /// The most-liked logos first. fanart.tv sometimes lists http:// asset URLs; ATS only allows https.
    private static func candidates(in logos: [FanartMusicResponse.Logo]?) -> [URL] {
        let sorted = (logos ?? []).sorted { (Int($0.likes ?? "") ?? 0) > (Int($1.likes ?? "") ?? 0) }
        return sorted.prefix(4).compactMap { URL(string: $0.url.replacingOccurrences(of: "http://", with: "https://")) }
    }

    /// Prefers a light logo, since the artist page is dark. Scores each candidate's visible
    /// pixels and takes the lightest; ties and unscorable logos fall back to most-liked.
    private static func lightest(of urls: [URL]) async -> URL? {
        guard urls.count > 1 else { return urls.first }
        var best: (url: URL, score: Double)?
        for url in urls {
            guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 256),
                  let score = ArtistLogoBrightness.score(of: image) else { continue }
            if best == nil || score > best!.score + 0.05 { best = (url, score) }
        }
        return best?.url ?? urls.first
    }

    /// Exact-name MusicBrainz match only, so a similarly named artist never gets the wrong logo.
    private static func musicBrainzID(forArtist name: String) async throws -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "musicbrainz.org"
        components.path = "/ws/2/artist/"
        components.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(name.replacingOccurrences(of: "\"", with: ""))\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        // MusicBrainz asks API clients to identify themselves.
        request.setValue("Tromme/1.0 (https://github.com/sweatyeggs69/Tromme)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(MusicBrainzSearchResponse.self, from: data)
        return decoded.artists.first {
            ($0.score ?? 0) >= 90 && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }?.id
    }

    // MARK: - Responses

    private struct FanartMusicResponse: Decodable {
        let hdmusiclogo: [Logo]?
        let musiclogo: [Logo]?

        struct Logo: Decodable {
            let url: String
            let likes: String?
        }
    }

    private struct MusicBrainzSearchResponse: Decodable {
        let artists: [Artist]

        struct Artist: Decodable {
            let id: String
            let name: String
            let score: Int?
        }
    }
}
