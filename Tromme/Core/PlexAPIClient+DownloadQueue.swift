import Foundation

// Download Queue endpoints, playback/transcode headers and artwork URLs.
extension PlexAPIClient {
    // MARK: - Download Queue

    /// Get or create this client's download queue. PMS scopes exactly one
    /// queue per client identifier + token, so this is safe to call before
    /// every download — it returns the existing queue id when one is
    /// already open. Endpoint: POST /downloadQueue.
    func getOrCreateDownloadQueue(server: PlexServer) async throws -> Int {
        guard let baseURL = server.baseURL,
              let url = URL(string: "/downloadQueue", relativeTo: baseURL) else {
            throw PlexAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyPlexHeaders(to: &request, token: server.accessToken)

        let response: DownloadQueueResponse = try await perform(request)
        guard let queueId = response.mediaContainer.downloadQueue?.first?.id else {
            throw PlexAPIError.serverError(-1)
        }
        return queueId
    }

    /// Adds a track to the download queue, requesting the MP3 conversion via
    /// the same `X-Plex-Client-Profile-Extra` directive used for streaming
    /// profile augmentation. Returns the queue item id used to poll status
    /// and fetch the resulting file. Endpoint: POST /downloadQueue/{queueId}/add.
    func addToDownloadQueue(
        server: PlexServer,
        queueId: Int,
        metadataPath: String,
        headers: [String: String],
        musicBitrate: Int
    ) async throws -> Int {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/downloadQueue/\(queueId)/add"
        components.queryItems = [
            URLQueryItem(name: "keys", value: metadataPath),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "directStreamAudio", value: "0"),
            URLQueryItem(name: "musicBitrate", value: "\(musicBitrate)"),
        ]
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")
        // playbackHeaders() (used to build `headers`) doesn't set Accept, and PMS
        // defaults to XML without it — which then fails to decode as JSON here.
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: DownloadQueueAddResponse = try await perform(request)
        guard let itemId = response.mediaContainer.addedQueueItems?.first?.id else {
            throw PlexAPIError.serverError(-1)
        }
        return itemId
    }

    /// Polls the current state of a queued download item.
    /// Endpoint: GET /downloadQueue/{queueId}/items/{itemId}.
    func downloadQueueItemStatus(server: PlexServer, queueId: Int, itemId: Int) async throws -> DownloadQueueItemStatus {
        guard let baseURL = server.baseURL,
              let url = URL(string: "/downloadQueue/\(queueId)/items/\(itemId)", relativeTo: baseURL) else {
            throw PlexAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        applyPlexHeaders(to: &request, token: server.accessToken)

        let response: DownloadQueueItemsResponse = try await perform(request)
        guard let item = response.mediaContainer.items?.first else {
            throw PlexAPIError.serverError(-1)
        }
        return item.status
    }

    /// Builds the request to fetch the finished file for a queue item once
    /// its status is `available`. Endpoint: GET /downloadQueue/{queueId}/item/{itemId}/media
    /// (note: singular "item", unlike the plural "items" used for status/delete).
    func downloadQueueMediaRequest(server: PlexServer, queueId: Int, itemId: Int) -> URLRequest? {
        guard let baseURL = server.baseURL,
              let url = URL(string: "/downloadQueue/\(queueId)/item/\(itemId)/media", relativeTo: baseURL) else {
            return nil
        }
        var request = URLRequest(url: url)
        applyPlexHeaders(to: &request, token: server.accessToken)
        return request
    }

    /// Removes a finished/failed item from the download queue.
    /// Best-effort cleanup; never throws — PMS will expire stale items on its own.
    /// Endpoint: DELETE /downloadQueue/{queueId}/items/{itemId}.
    func deleteDownloadQueueItem(server: PlexServer, queueId: Int, itemId: Int) async {
        guard let baseURL = server.baseURL,
              let url = URL(string: "/downloadQueue/\(queueId)/items/\(itemId)", relativeTo: baseURL) else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyPlexHeaders(to: &request, token: server.accessToken)
        _ = try? await session.data(for: request)
    }

    /// Transcode-target profile for converted offline downloads.
    /// Must be context=static: the Download Queue's decision engine evaluates
    /// a one-shot, non-realtime conversion — context=streaming here yields
    /// "decisionError" and PMS never transcodes at all. `replace=true` is
    /// required so this target overrides the Generic profile's existing one.
    /// Only MP3 works here — PMS's progressive http muxer produces zero bytes
    /// for AAC (ADTS) and MP4 output.
    static func profileExtraDownload(container: String, codec: String) -> String {
        "add-transcode-target(type=musicProfile&context=static&protocol=http&container=\(container)&audioCodec=\(codec)&replace=true)"
    }

    func downloadTranscodeHeaders(
        server: PlexServer,
        sessionID: String,
        container: String,
        codec: String
    ) -> [String: String] {
        var headers = playbackHeaders(server: server, sessionID: sessionID)
        headers["X-Plex-Client-Profile-Extra"] = Self.profileExtraDownload(container: container, codec: codec)
        return headers
    }

    /// ALAC profile for LAN — lossless, no quality loss. Only appropriate when
    /// the source is FLAC; using it for already-compatible codecs (e.g. AAC)
    /// would make PMS re-encode lossy audio into a bloated lossless container
    /// for no quality gain.
    static let profileExtraLAN: String =
        "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mp4&audioCodec=alac)"

    /// AAC profile for cellular — lossy but bandwidth-friendly.
    static let profileExtraCellular: String =
        "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mp4&audioCodec=aac)"

    /// Targets the source's own audio codec so PMS remuxes into HLS instead
    /// of re-encoding audio that's already compatible (e.g. AAC, MP3).
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
            "X-Plex-Provides": "player",
            "X-Plex-Client-Profile-Name": "Generic",
            "X-Plex-Client-Profile-Extra": profileExtra,
        ]
        if let sessionID {
            headers["X-Plex-Session-Identifier"] = sessionID
        }
        return headers
    }

    /// Build a transcoded artwork URL with Plex identification.
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
