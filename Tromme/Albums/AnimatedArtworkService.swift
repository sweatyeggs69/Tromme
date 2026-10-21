import Foundation

/// Looks up animated artwork on the Tromme artwork service, which caches results itself.
enum AnimatedArtworkService {
    private struct Response: Decodable {
        let url: String?
        let url_tall: String?
    }

    /// Whether audio has buffered enough for artwork to start loading. Set by the player.
    @MainActor static var isAudioBuffered: () -> Bool = { true }

    /// Holds artwork back until 30 s of the current track is buffered, so clips never
    /// compete with the audio for a weak connection. Returns at once when nothing is playing.
    @MainActor private static func waitForAudioBuffer() async {
        while !isAudioBuffered(), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The album's animated artwork, or nil when it has none, the feature is off, or
    /// the lookup fails (network error, timeout, non-200). Failures stay silent: the
    /// static artwork simply stays.
    static func artwork(artist: String, album: String) async -> AnimatedArtwork? {
        guard AnimatedArtworkEntitlement.isEnabled else { return nil }
        await waitForAudioBuffer()
        guard !Task.isCancelled else { return nil }
        var components = URLComponents(string: "https://amaa.tromme.app/api/v1/artwork/search")
        components?.queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "album", value: album)
        ]
        guard let url = components?.url else { return nil }
        do {
            // The service caches results itself; bypass URLSession's cache so a stale or wrong match is never replayed.
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
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
