import Foundation

/// Looks up the tall animated artwork (HLS) for an album. The service caches, so there is no client cache.
enum AnimatedArtworkService {
    private static let timeout: TimeInterval = 5

    private struct Response: Decodable {
        let urlTall: URL?
        enum CodingKeys: String, CodingKey { case urlTall = "url_tall" }
    }

    /// Returns nil on any failure, timeout or when the album has no tall artwork.
    static func tallURL(artist: String, album: String) async -> URL? {
        var components = URLComponents(string: "https://amaa.tromme.app/api/v1/artwork/search")
        components?.queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "album", value: album)
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Response.self, from: data).urlTall
        } catch {
            #if DEBUG
            print("[AnimatedArtwork] lookup failed: \(error)")
            #endif
            return nil
        }
    }
}
