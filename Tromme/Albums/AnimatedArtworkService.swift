import Foundation

enum AnimatedArtworkService {
    private struct Response: Decodable {
        let url: String?
        let url_tall: String?
    }

    @MainActor static var isAudioBuffered: () -> Bool = { true }

    @MainActor private static func waitForAudioBuffer() async {
        while !isAudioBuffered(), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    static func artwork(artist: String, album: String) async -> AnimatedArtwork? {
        guard AnimatedArtworkEntitlement.isEnabled else { return nil }
        await waitForAudioBuffer()
        guard !Task.isCancelled else { return nil }
        var components = URLComponents(string: "https://api.tromme.app/artwork/search")
        components?.queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "album", value: album)
        ]
        guard let url = components?.url else { return nil }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.allowsConstrainedNetworkAccess = false
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
