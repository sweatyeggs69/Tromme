import Foundation

extension PlexAPIClient {
    static let profileExtraLAN: String =
        "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mp4&audioCodec=alac)"

    static let profileExtraCellular: String =
        "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mp4&audioCodec=aac)"

    static func profileExtraPassthrough(codec: String) -> String {
        "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mp4&audioCodec=\(codec))"
    }

    func playbackHeaders(
        server: PlexServer,
        sessionID: String?,
        preferAACTranscode: Bool = false,
        avoidAudioTranscode: Bool = false,
        sourceCodec: String? = nil
    ) -> [String: String] {
        let profileExtra: String
        if avoidAudioTranscode {
            switch sourceCodec?.lowercased() {
            case "flac", nil:
                profileExtra = Self.profileExtraLAN
            case .some(let codec):
                profileExtra = Self.profileExtraPassthrough(codec: codec)
            }
        } else if preferAACTranscode {
            profileExtra = Self.profileExtraCellular
        } else {
            profileExtra = Self.profileExtraLAN
        }
        var headers: [String: String] = [
            "X-Plex-Token": server.accessToken,
            "X-Plex-Client-Identifier": Self.clientIdentifier,
            "X-Plex-Product": Self.product,
            "X-Plex-Version": Self.version,
            "X-Plex-Platform": Self.platform,
            "X-Plex-Platform-Version": Self.platformVersion,
            "X-Plex-Device": Self.device,
            "X-Plex-Device-Name": Self.deviceName,
            "X-Plex-Client-Profile-Name": "Generic",
            "X-Plex-Client-Profile-Extra": profileExtra,
        ]
        if let sessionID {
            headers["X-Plex-Session-Identifier"] = sessionID
        }
        return headers
    }

    func artworkURL(server: PlexServer, path: String?, width: Int = 400, height: Int = 400) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/photo/:/transcode"
        components.queryItems = [
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier),
        ]
        return components.url
    }
}
