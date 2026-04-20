import Foundation

enum PlexAPIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int)
    case networkError(Error)
    case decodingError(Error, path: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .unauthorized: return "Authentication required"
        case .serverError(let code): return "Server error (\(code))"
        case .networkError(let error): return error.localizedDescription
        case .decodingError(let error, let path):
            if let decodingError = error as? DecodingError {
                return "Parse error at \(path): \(decodingError.detailedDescription)"
            }
            return "Parse error at \(path): \(error.localizedDescription)"
        }
    }
}

extension DecodingError {
    var detailedDescription: String {
        switch self {
        case .keyNotFound(let key, let context):
            "Missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(let type, let context):
            "Expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(let type, let context):
            "Null value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context):
            "Invalid data at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            localizedDescription
        }
    }
}

final class PlexAPIClient: Sendable {
    // Required Plex identification headers (per API spec)
    static let clientIdentifier = "com.kylemcclain.Tromme"
    static let product = "Tromme"
    static let version = "1.0.0"
    static let platform = "iOS"
    static let platformVersion = ProcessInfo.processInfo.operatingSystemVersionString
    static let device = "iPhone"
    static let deviceName = "Tromme iOS"
    static let defaultContainerStart = "0"
    static let defaultContainerSize = "200"

    private let session: URLSession

    /// Default session configured for reliability on all network types.
    /// `waitsForConnectivity` ensures requests don't fail instantly on cellular
    /// when connectivity is briefly interrupted (e.g., handoff between towers).
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    /// Applies the full set of X-Plex-* identification headers to a request.
    /// Per the API spec, these headers should be included on all requests.
    private func applyPlexHeaders(to request: inout URLRequest) {
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(Self.product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(Self.version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(Self.platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(Self.platformVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(Self.device, forHTTPHeaderField: "X-Plex-Device")
        request.setValue(Self.deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    // MARK: - Plex.tv Auth Endpoints

    func createPin() async throws -> PlexPinResponse {
        var request = plexTVRequest(path: "/api/v2/pins", method: "POST")
        request.httpBody = "strong=true".data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    func checkPin(id: Int) async throws -> PlexPinResponse {
        let request = plexTVRequest(path: "/api/v2/pins/\(id)", method: "GET")
        return try await perform(request)
    }

    func getResources(token: String) async throws -> [PlexResource] {
        var request = plexTVRequest(path: "/api/v2/resources?includeHttps=1&includeRelay=1", method: "GET")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return try await perform(request)
    }

    // MARK: - Library Endpoints

    func getLibrarySections(server: PlexServer) async throws -> [LibrarySection] {
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: "/library/sections"
        )
        return response.mediaContainer.directory ?? []
    }

    func getLibraryContents(server: PlexServer, sectionId: String, type: Int? = nil) async throws -> [PlexMetadata] {
        let pageSize = 200
        var allItems: [PlexMetadata] = []
        var start = 0

        while true {
            var path = "/library/sections/\(sectionId)/all?X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(pageSize)"
            if let type {
                path += "&type=\(type)"
            }
            let response: PlexResponse<PlexMetadata> = try await retryingRequest {
                try await self.serverRequest(server: server, path: path)
            }
            let items = response.mediaContainer.metadata ?? []
            allItems.append(contentsOf: items)

            let total = response.mediaContainer.totalSize ?? items.count
            start += items.count
            if start >= total || items.isEmpty { break }
        }

        return allItems
    }

    /// Fetch tracks considered favorites by Plex (typically user-rated 4+ stars).
    func getFavoriteTracks(server: PlexServer, sectionId: String, minUserRating: Int = 4) async throws -> [PlexMetadata] {
        let path = "/library/sections/\(sectionId)/all?type=10&track.userRating>=\(minUserRating)"
        let response: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: path)
        return response.mediaContainer.metadata ?? []
    }

    func getTopTracks(server: PlexServer, sectionId: String, artistRatingKey: String, limit: Int = 10) async throws -> [PlexMetadata] {
        let path = "/library/sections/\(sectionId)/all?type=10&artist.id=\(artistRatingKey)&sort=viewCount:desc&X-Plex-Container-Start=0&X-Plex-Container-Size=\(limit)"
        let response: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: path)
        return response.mediaContainer.metadata ?? []
    }

    func getRecentlyAdded(server: PlexServer, sectionId: String, type: Int = 9, limit: Int = 10) async throws -> [PlexMetadata] {
        let path = "/library/sections/\(sectionId)/all?type=\(type)&sort=addedAt:desc&X-Plex-Container-Start=0&X-Plex-Container-Size=\(limit)"
        let response: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: path)
        return response.mediaContainer.metadata ?? []
    }

    func getRecentlyPlayed(server: PlexServer, sectionId: String, limit: Int = 10) async throws -> [PlexMetadata] {
        let path = "/library/sections/\(sectionId)/all?type=10&sort=lastViewedAt:desc&lastViewedAt>=1&X-Plex-Container-Start=0&X-Plex-Container-Size=\(limit)"
        let response: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: path)
        return response.mediaContainer.metadata ?? []
    }

    func getMetadataChildren(server: PlexServer, ratingKey: String) async throws -> [PlexMetadata] {
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: "/library/metadata/\(ratingKey)/children"
        )
        return response.mediaContainer.metadata ?? []
    }

    func getMetadata(server: PlexServer, ratingKey: String) async throws -> PlexMetadata? {
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: "/library/metadata/\(ratingKey)"
        )
        return response.mediaContainer.metadata?.first
    }

    // MARK: - Search

    func search(server: PlexServer, query: String, sectionId: String? = nil, limit: Int = 20) async throws -> [Hub] {
        var path = "/hubs/search?query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&limit=\(limit)"
        if let sectionId {
            path += "&sectionId=\(sectionId)"
        }
        let response: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: path)
        return response.mediaContainer.hub ?? []
    }

    // MARK: - Playlists

    func getPlaylists(server: PlexServer) async throws -> [PlexPlaylist] {
        let data = try await rawServerRequest(server: server, path: "/playlists")
        let decoded = try JSONDecoder().decode(PlexResponse<PlexPlaylist>.self, from: data)
        return decoded.mediaContainer.metadata ?? []
    }

    func getPlaylistItems(server: PlexServer, playlistKey: String) async throws -> [PlexMetadata] {
        let normalizedPath: String
        if playlistKey.hasPrefix("/playlists/") {
            normalizedPath = playlistKey.hasSuffix("/items") ? playlistKey : "\(playlistKey)/items"
        } else {
            normalizedPath = "/playlists/\(playlistKey)/items"
        }
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: normalizedPath
        )
        return response.mediaContainer.metadata ?? []
    }

    func addItemsToPlaylist(server: PlexServer, playlistId: String, itemRatingKeys: [String]) async throws {
        let normalizedItemKeys = orderedUniqueItemKeys(from: itemRatingKeys)
        guard !normalizedItemKeys.isEmpty else { return }

        let uri = playlistMetadataURI(server: server, itemRatingKeys: normalizedItemKeys)
        let queryItems = [URLQueryItem(name: "uri", value: uri)]
        _ = try await rawServerRequest(
            server: server,
            path: "/playlists/\(playlistId)/items",
            method: "PUT",
            queryItems: queryItems
        )
    }

    func createPlaylist(
        server: PlexServer,
        title: String,
        playlistType: String = "audio",
        itemRatingKeys: [String]
    ) async throws -> PlexPlaylist {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedItemKeys = orderedUniqueItemKeys(from: itemRatingKeys)
        guard !normalizedItemKeys.isEmpty else { throw PlexAPIError.invalidURL }
        let uri = playlistMetadataURI(server: server, itemRatingKeys: normalizedItemKeys)
        let queryItems = [
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "title", value: trimmedTitle),
            URLQueryItem(name: "type", value: playlistType),
            URLQueryItem(name: "smart", value: "0"),
        ]
        let data = try await rawServerRequest(
            server: server,
            path: "/playlists",
            method: "POST",
            queryItems: queryItems
        )
        do {
            let decoded = try JSONDecoder().decode(PlexResponse<PlexPlaylist>.self, from: data)
            if let playlist = decoded.mediaContainer.metadata?.first {
                return playlist
            }
            throw PlexAPIError.decodingError(
                DecodingError.valueNotFound(
                    PlexPlaylist.self,
                    .init(codingPath: [], debugDescription: "No playlist returned from create endpoint.")
                ),
                path: "/playlists"
            )
        } catch let error as PlexAPIError {
            throw error
        } catch {
            throw PlexAPIError.decodingError(error, path: "/playlists")
        }
    }

    func deletePlaylist(server: PlexServer, playlistId: String) async throws {
        _ = try await rawServerRequest(
            server: server,
            path: "/playlists/\(playlistId)",
            method: "DELETE"
        )
    }

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
        continuing: Bool = false
    ) async throws {
        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/:/timeline"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: "\(timeMs)"),
            URLQueryItem(name: "duration", value: "\(durationMs)"),
        ]
        if state == "stopped" {
            items.append(URLQueryItem(name: "continuing", value: continuing ? "1" : "0"))
        }
        components.queryItems = items

        guard let url = components.url else { throw PlexAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyPlexHeaders(to: &request)
        request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if statusCode >= 400 {
            print("[AudioPlayer] Timeline report failed: status \(statusCode)")
        }
    }

    /// Mark an item as played in Plex history.
    /// Endpoint: /:/scrobble
    func reportScrobble(server: PlexServer, ratingKey: String) async throws {
        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/:/scrobble"
        components.queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ]

        guard let url = components.url else { throw PlexAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyPlexHeaders(to: &request)
        request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if statusCode >= 400 {
            print("[AudioPlayer] Scrobble failed: status \(statusCode)")
        }
    }

    /// Build a direct stream URL with full Plex identification query params.
    func streamURL(server: PlexServer, partKey: String) -> URL? {
        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = partKey
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: Self.product),
            URLQueryItem(name: "X-Plex-Platform", value: Self.platform),
        ]
        return components.url
    }

    /// Common query items shared between the decision and start endpoints.
    private func universalQueryItems(
        server: PlexServer,
        metadataPath: String,
        sessionID: String,
        cellular: Bool = false,
        disableCellularTranscoding: Bool = false,
        cellularTranscodeBitrate: Int = 320
    ) -> [URLQueryItem] {
        let musicBitrate = cellular && !disableCellularTranscoding ? "\(cellularTranscodeBitrate)" : "40000"
        return [
            URLQueryItem(name: "path", value: metadataPath),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "musicBitrate", value: musicBitrate),
            URLQueryItem(name: "mediaBufferSize", value: "102400"),
            URLQueryItem(name: "location", value: cellular ? "cellular" : "lan"),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "transcodeSessionId", value: sessionID),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: Self.clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: Self.product),
            URLQueryItem(name: "X-Plex-Platform", value: Self.platform),
            URLQueryItem(name: "X-Plex-Version", value: Self.version),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID),
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
        ]
    }

    /// Call the decision endpoint to authorize the transcode session before streaming.
    /// PMS requires this before the start endpoint will serve content.
    func universalDecision(
        server: PlexServer,
        metadataPath: String,
        sessionID: String,
        headers: [String: String],
        cellular: Bool = false,
        disableCellularTranscoding: Bool = false,
        cellularTranscodeBitrate: Int = 320
    ) async throws {
        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/music/:/transcode/universal/decision"
        components.queryItems = universalQueryItems(
            server: server,
            metadataPath: metadataPath,
            sessionID: sessionID,
            cellular: cellular,
            disableCellularTranscoding: disableCellularTranscoding,
            cellularTranscodeBitrate: cellularTranscodeBitrate
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
                print("[AudioPlayer] Decision failed with status \(statusCode)")
                throw PlexAPIError.serverError(statusCode)
            }
        }
    }

    /// Build the universal transcode HLS master playlist URL.
    func universalStreamURLCandidates(
        server: PlexServer,
        mediaPathCandidates: [String],
        sessionID: String,
        cellular: Bool = false,
        disableCellularTranscoding: Bool = false,
        cellularTranscodeBitrate: Int = 320
    ) -> [URL] {
        let path = mediaPathCandidates.first ?? "/library/metadata/0"
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else { return [] }
        components.path = "/music/:/transcode/universal/start.m3u8"
        components.queryItems = universalQueryItems(
            server: server,
            metadataPath: normalizedPath,
            sessionID: sessionID,
            cellular: cellular,
            disableCellularTranscoding: disableCellularTranscoding,
            cellularTranscodeBitrate: cellularTranscodeBitrate
        )

        guard let url = components.url else { return [] }
        return [url]
    }

    /// ALAC profile for LAN — lossless, no quality loss.
    static let profileExtraLAN: String =
        "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mp4&audioCodec=alac)"

    /// AAC profile for cellular — lossy but bandwidth-friendly.
    static let profileExtraCellular: String =
        "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mp4&audioCodec=aac)"

    func playbackHeaders(
        server: PlexServer,
        sessionID: String?,
        cellular: Bool = false,
        disableCellularTranscoding: Bool = false
    ) -> [String: String] {
        let avoidCellularAudioTranscode = cellular && disableCellularTranscoding
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
            "X-Plex-Client-Profile-Extra": avoidCellularAudioTranscode ? Self.profileExtraLAN : (cellular ? Self.profileExtraCellular : Self.profileExtraLAN),
        ]
        if let sessionID {
            headers["X-Plex-Session-Identifier"] = sessionID
        }
        return headers
    }

    /// Build a transcoded artwork URL with Plex identification.
    func artworkURL(server: PlexServer, path: String?, width: Int = 400, height: Int = 400) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else { return nil }
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

    // MARK: - Private Helpers

    /// Retry a request up to `maxRetries` times for transient network errors.
    /// Only retries on network errors (timeout, connection lost) — not on
    /// server errors (4xx/5xx) or decoding failures.
    private func retryingRequest<T>(maxRetries: Int = 2, _ operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch let error as PlexAPIError {
                switch error {
                case .networkError:
                    lastError = error
                    if attempt < maxRetries {
                        try? await Task.sleep(for: .seconds(Double(attempt + 1)))
                    }
                default:
                    throw error
                }
            } catch {
                lastError = error
                if attempt < maxRetries {
                    try? await Task.sleep(for: .seconds(Double(attempt + 1)))
                }
            }
        }
        throw lastError!
    }

    /// Build a request to plex.tv with all required identification headers.
    private func plexTVRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://plex.tv\(path)")!)
        request.httpMethod = method
        applyPlexHeaders(to: &request)
        return request
    }

    /// Execute a typed JSON request against a Plex Media Server.
    private func serverRequest<T: Decodable>(server: PlexServer, path: String, method: String = "GET") async throws -> T {
        let data = try await rawServerRequest(server: server, path: path, method: method)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PlexAPIError.decodingError(error, path: path)
        }
    }

    /// Execute a raw request against a Plex Media Server with all required headers.
    @discardableResult
    private func rawServerRequest(server: PlexServer, path: String, method: String = "GET") async throws -> Data {
        guard let url = URL(string: path, relativeTo: server.baseURL) else {
            throw PlexAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyPlexHeaders(to: &request)
        request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")
        if method == "GET", shouldIncludeContainerHeaders(for: path),
           !path.contains("X-Plex-Container-Start") {
            request.setValue(Self.defaultContainerStart, forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue(Self.defaultContainerSize, forHTTPHeaderField: "X-Plex-Container-Size")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlexAPIError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidURL
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw PlexAPIError.unauthorized }
            throw PlexAPIError.serverError(http.statusCode)
        }
        return data
    }

    /// Execute a raw request against a Plex Media Server with URL-encoded query items.
    @discardableResult
    private func rawServerRequest(
        server: PlexServer,
        path: String,
        method: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: true) else {
            throw PlexAPIError.invalidURL
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyPlexHeaders(to: &request)
        request.setValue(server.accessToken, forHTTPHeaderField: "X-Plex-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlexAPIError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidURL
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw PlexAPIError.unauthorized }
            throw PlexAPIError.serverError(http.statusCode)
        }
        return data
    }

    private func shouldIncludeContainerHeaders(for path: String) -> Bool {
        if path.hasPrefix("/library/sections/"), path.contains("/all") {
            return true
        }
        if path.hasPrefix("/library/metadata/"), path.hasSuffix("/children") {
            return true
        }
        if path.hasPrefix("/hubs/search") {
            return true
        }
        if path == "/playlists" {
            return true
        }
        if path.hasPrefix("/playlists/"), path.hasSuffix("/items") {
            return true
        }
        return false
    }

    private func playlistMetadataURI(server: PlexServer, itemRatingKeys: [String]) -> String {
        let joinedKeys = itemRatingKeys.joined(separator: ",")
        return "server://\(server.machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(joinedKeys)"
    }

    private func orderedUniqueItemKeys(from itemRatingKeys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in itemRatingKeys where !key.isEmpty {
            if seen.insert(key).inserted {
                result.append(key)
            }
        }
        return result
    }

    /// Execute a typed request against plex.tv.
    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PlexAPIError.invalidURL
            }
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 401 { throw PlexAPIError.unauthorized }
                throw PlexAPIError.serverError(http.statusCode)
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as PlexAPIError {
            throw error
        } catch let error as DecodingError {
            throw PlexAPIError.decodingError(error, path: request.url?.path ?? "plex.tv")
        } catch {
            throw PlexAPIError.networkError(error)
        }
    }
}
