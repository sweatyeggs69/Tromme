import Foundation

/// Looks up animated artwork on the Tromme artwork service, which caches results itself.
enum AnimatedArtworkService {
    private struct Response: Decodable {
        let url: String?
        let url_tall: String?
    }

    /// The album's animated artwork, or nil when it has none, the feature is off, or
    /// the lookup fails (network error, timeout, non-200). Failures stay silent: the
    /// static artwork simply stays.
    static func artwork(artist: String, album: String) async -> AnimatedArtwork? {
        guard AnimatedArtworkEntitlement.isEnabled else { return nil }
        var components = URLComponents(string: "https://amaa.tromme.app/api/v1/artwork/search")
        components?.queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "album", value: album)
        ]
        guard let url = components?.url else { return nil }
        do {
            let request = URLRequest(url: url, timeoutInterval: 5)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let artwork = AnimatedArtwork(
                square: decoded.url.flatMap(URL.init(string:)),
                tall: decoded.url_tall.flatMap(URL.init(string:))
            )
            return artwork.isEmpty ? nil : artwork
        } catch {
            #if DEBUG
            print("[AnimatedArtwork] lookup failed: \(error)")
            #endif
            return nil
        }
    }
}
