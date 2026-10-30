import Foundation

extension PlexAPIClient {
    // MARK: - Playback

    /// Report playback state to PMS so it appears in the dashboard.
    /// Per API spec: POST /:/timeline with state, time, duration, key, ratingKey.
    /// Requires X-Plex-Session-Identifier header to associate with the playback session.
    func reportTimeline(
        server: PlexServer,
        ratingKey: String,
        key: String,
        state: String,
        timeMs: Int,
        durationMs: Int,
        sessionID: String?,
        continuing: Bool = false,
        offline: Bool = false,
        updated: Int? = nil
    ) async throws {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/:/timeline"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: "\(timeMs)"),
            URLQueryItem(name: "duration", value: "\(durationMs)"),
        ]
        if state == "stopped" {
            items.append(URLQueryItem(name: "continuing", value: continuing ? "1" : "0"))
        }
        if offline {
            items.append(URLQueryItem(name: "offline", value: "1"))
        }
        if let updated {
            items.append(URLQueryItem(name: "updated", value: "\(updated)"))
        }
        components.queryItems = items

        guard let url = components.url else { throw PlexAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyPlexHeaders(to: &request, token: server.accessToken)
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if statusCode >= 400 {
            #if DEBUG
            print("[AudioPlayer] Timeline report failed: status \(statusCode)")
            #endif
        }
    }

    func rateItem(server: PlexServer, ratingKey: String, rating: Int) async throws {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/:/rate"
        components.queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "rating", value: "\(rating)"),
        ]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyPlexHeaders(to: &request, token: server.accessToken)

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            if statusCode == 401 { throw PlexAPIError.unauthorized }
            throw PlexAPIError.serverError(statusCode)
        }
    }

    func downloadURL(server: PlexServer, partKey: String) -> URL? {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: Self.product),
            URLQueryItem(name: "X-Plex-Platform", value: Self.platform),
            URLQueryItem(name: "download", value: "1"),
        ]
        return components.url
    }

    func streamURL(server: PlexServer, partKey: String) -> URL? {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: Self.product),
            URLQueryItem(name: "X-Plex-Platform", value: Self.platform),
        ]
        return components.url
    }

    private func universalQueryItems(
        server: PlexServer,
        metadataPath: String,
        sessionID: String,
        location: String = "lan",
        streamProtocol: String = "hls",
        allowDirectStream: Bool = true,
        constrainAudioBitrate: Bool = false,
        cellularTranscodeBitrate: Int = 320,
        offsetSeconds: Int = 0
    ) -> [URLQueryItem] {
        let musicBitrate = constrainAudioBitrate ? "\(cellularTranscodeBitrate)" : "40000"
        let directStream = allowDirectStream ? "1" : "0"
        return [
            URLQueryItem(name: "path", value: metadataPath),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "offset", value: "\(max(offsetSeconds, 0))"),
            URLQueryItem(name: "protocol", value: streamProtocol),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: directStream),
            URLQueryItem(name: "directStreamAudio", value: directStream),
            URLQueryItem(name: "musicBitrate", value: musicBitrate),
            URLQueryItem(name: "mediaBufferSize", value: "102400"),
            URLQueryItem(name: "location", value: location),
            URLQueryItem(name: "transcodeSessionId", value: sessionID),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: Self.product),
            URLQueryItem(name: "X-Plex-Platform", value: Self.platform),
            URLQueryItem(name: "X-Plex-Version", value: Self.version),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID),
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
        ]
    }

    func universalDecision(
        server: PlexServer,
        metadataPath: String,
        sessionID: String,
        headers: [String: String],
        location: String = "lan",
        streamProtocol: String = "hls",
        allowDirectStream: Bool = true,
        constrainAudioBitrate: Bool = false,
        cellularTranscodeBitrate: Int = 320,
        offsetSeconds: Int = 0
    ) async throws {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/music/:/transcode/universal/decision"
        components.queryItems = universalQueryItems(
            server: server,
            metadataPath: metadataPath,
            sessionID: sessionID,
            location: location,
            streamProtocol: streamProtocol,
            allowDirectStream: allowDirectStream,
            constrainAudioBitrate: constrainAudioBitrate,
            cellularTranscodeBitrate: cellularTranscodeBitrate,
            offsetSeconds: offsetSeconds
        )

        guard let url = components.url else { throw PlexAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        try await retryingRequest {
            let (_, response): (Data, URLResponse)
            do {
                ( _, response) = try await self.session.data(for: request)
            } catch {
                throw PlexAPIError.networkError(error)
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusCode >= 400 {
                #if DEBUG
                print("[AudioPlayer] Decision failed with status \(statusCode)")
                #endif
                throw PlexAPIError.serverError(statusCode)
            }
        }
    }

    func universalStreamURLCandidates(
        server: PlexServer,
        mediaPathCandidates: [String],
        sessionID: String,
        location: String = "lan",
        constrainAudioBitrate: Bool = false,
        cellularTranscodeBitrate: Int = 320,
        offsetSeconds: Int = 0
    ) -> [URL] {
        let path = mediaPathCandidates.first ?? "/library/metadata/0"
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return [] }
        components.path = "/music/:/transcode/universal/start.m3u8"
        components.queryItems = universalQueryItems(
            server: server,
            metadataPath: normalizedPath,
            sessionID: sessionID,
            location: location,
            constrainAudioBitrate: constrainAudioBitrate,
            cellularTranscodeBitrate: cellularTranscodeBitrate,
            offsetSeconds: offsetSeconds
        )

        guard let url = components.url else { return [] }
        return [url]
    }

    func directStreamURL(server: PlexServer, partKey: String) -> URL? {
        let normalizedPath = partKey.hasPrefix("/") ? partKey : "/\(partKey)"
        guard var partComponents = URLComponents(string: normalizedPath),
              let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }

        var queryItems = partComponents.queryItems ?? []
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: server.accessToken))
        queryItems.append(URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier))
        partComponents.queryItems = queryItems

        components.path = partComponents.path
        components.queryItems = partComponents.queryItems
        return components.url
    }

    func resolveUniversalVariantURL(masterURL: URL) async -> URL? {
        guard let (data, response) = try? await session.data(from: masterURL),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix("#EXT-X-STREAM-INF"), index + 1 < lines.count else { continue }
            let uri = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if !uri.isEmpty, !uri.hasPrefix("#") {
                return URL(string: uri, relativeTo: masterURL)?.absoluteURL
            }
        }
        for line in lines where !line.hasPrefix("#") {
            return URL(string: line, relativeTo: masterURL)?.absoluteURL
        }
        return nil
    }
}
