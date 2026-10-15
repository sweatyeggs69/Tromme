import Foundation

/// Downloads an animated artwork HLS stream as the bytes of one playable MP4, for
/// places that need a video file instead of a stream (the lock screen).
enum AnimatedArtworkClipDownloader {
    /// Widest variant to pick from the master playlist; the lock screen doesn't need more.
    private static let maxVariantWidth = 1080

    static func clipData(from streamURL: URL) async -> Data? {
        do {
            let playlistURL = try await mediaPlaylistURL(from: streamURL)
            let parts = try await partURLs(in: playlistURL)
            // MPEG-TS segments can't be joined into an MP4 by concatenation.
            guard !parts.isEmpty, !parts.contains(where: { $0.pathExtension.lowercased() == "ts" }) else { return nil }
            var data = Data()
            for part in parts {
                try Task.checkCancellation()
                data.append(try await fetch(part))
            }
            return data
        } catch {
            #if DEBUG
            print("[AnimatedArtwork] clip download failed: \(error)")
            #endif
            return nil
        }
    }

    /// The variant playlist to download: the widest one up to `maxVariantWidth`,
    /// else the narrowest. A plain media playlist is returned as is.
    private static func mediaPlaylistURL(from url: URL) async throws -> URL {
        let lines = try await playlistLines(at: url)
        var variants: [(url: URL, width: Int)] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            guard index + 1 < lines.count, !lines[index + 1].hasPrefix("#"),
                  let variantURL = URL(string: lines[index + 1], relativeTo: url)?.absoluteURL else { continue }
            let width = line.firstMatch(of: /RESOLUTION=(\d+)x\d+/).flatMap { Int($0.1) } ?? 0
            variants.append((variantURL, width))
        }
        guard !variants.isEmpty else { return url }
        let fitting = variants.filter { $0.width <= maxVariantWidth }.max { $0.width < $1.width }
        return (fitting ?? variants.min { $0.width < $1.width })!.url
    }

    /// The files a media playlist plays, in order: the init segment first, then each
    /// distinct media file. Apple's clips usually list one MP4 by byte ranges, so
    /// fetching each distinct file whole yields one complete MP4.
    private static func partURLs(in playlistURL: URL) async throws -> [URL] {
        var urls: [URL] = []
        for line in try await playlistLines(at: playlistURL) {
            let path: String?
            if line.hasPrefix("#EXT-X-MAP:") {
                path = line.firstMatch(of: /URI="([^"]+)"/).map { String($0.1) }
            } else {
                path = line.hasPrefix("#") ? nil : line
            }
            guard let path, let url = URL(string: path, relativeTo: playlistURL)?.absoluteURL,
                  !urls.contains(url) else { continue }
            urls.append(url)
        }
        return urls
    }

    private static func playlistLines(at url: URL) async throws -> [String] {
        let data = try await fetch(url)
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
