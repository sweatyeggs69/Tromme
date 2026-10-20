import Foundation

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

    let session: URLSession

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
    func applyPlexHeaders(to request: inout URLRequest, token: String? = nil) {
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(Self.product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(Self.version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(Self.platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(Self.platformVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(Self.device, forHTTPHeaderField: "X-Plex-Device")
        request.setValue(Self.deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    }

    // MARK: - Plex.tv Auth Endpoints

    func createPin() async throws -> PlexPinResponse {
        var request = try plexTVRequest(path: "/api/v2/pins", method: "POST")
        request.httpBody = "strong=true".data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    func checkPin(id: Int) async throws -> PlexPinResponse {
        let request = try plexTVRequest(path: "/api/v2/pins/\(id)", method: "GET")
        return try await perform(request)
    }

    func getResources(token: String) async throws -> [PlexResource] {
        var request = try plexTVRequest(path: "/api/v2/resources?includeHttps=1&includeRelay=1", method: "GET")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return try await perform(request)
    }

    // MARK: - Private Helpers

    /// Retry a request up to `maxRetries` times for transient network errors.
    /// Only retries on network errors (timeout, connection lost) — not on
    /// server errors (4xx/5xx) or decoding failures.
    func retryingRequest<T>(maxRetries: Int = 2, _ operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch let error as PlexAPIError {
                switch error {
                case .networkError:
                    lastError = error
                    if attempt < maxRetries {
                        try await Task.sleep(for: .seconds(Double(attempt + 1)))
                    }
                default:
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw error
            }
        }
        if let lastError {
            throw lastError
        } else {
            throw PlexAPIError.networkError(URLError(.unknown))
        }
    }

    /// Build a request to plex.tv with all required identification headers.
    func plexTVRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: "https://plex.tv\(path)") else {
            throw PlexAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyPlexHeaders(to: &request)
        return request
    }

    /// Execute a typed JSON request against a Plex Media Server.
    func serverRequest<T: Decodable>(server: PlexServer, path: String, method: String = "GET") async throws -> T {
        let data = try await rawServerRequest(server: server, path: path, method: method)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PlexAPIError.decodingError(error, path: path)
        }
    }

    /// Execute a raw request against a Plex Media Server with all required headers.
    @discardableResult
    func rawServerRequest(server: PlexServer, path: String, method: String = "GET") async throws -> Data {
        guard let baseURL = server.baseURL,
              let url = URL(string: path, relativeTo: baseURL) else {
            throw PlexAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyPlexHeaders(to: &request, token: server.accessToken)
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
    func rawServerRequest(
        server: PlexServer,
        path: String,
        method: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw PlexAPIError.invalidURL
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyPlexHeaders(to: &request, token: server.accessToken)

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

    func shouldIncludeContainerHeaders(for path: String) -> Bool {
        if path.hasPrefix("/library/sections/"), path.contains("/all") {
            return true
        }
        if path.hasPrefix("/library/metadata/"), path.hasSuffix("/allLeaves") {
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

    func playlistMetadataURI(server: PlexServer, itemRatingKeys: [String]) -> String {
        let joinedKeys = itemRatingKeys.joined(separator: ",")
        return "server://\(server.machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(joinedKeys)"
    }

    func orderedUniqueItemKeys(from itemRatingKeys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in itemRatingKeys where !key.isEmpty {
            if seen.insert(key).inserted {
                result.append(key)
            }
        }
        return result
    }

    func parseArtworkResourcesXML(_ data: Data) -> [PlexImageResource] {
        let parserDelegate = ArtworkXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        let didParse = parser.parse()
        guard didParse else { return [] }
        return parserDelegate.images
    }

    func setArtworkResource(
        server: PlexServer,
        ratingKey: String,
        element: String,
        artworkURL: String,
        method: String
    ) async throws {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/library/metadata/\(ratingKey)/\(element)"
        components.queryItems = [URLQueryItem(name: "url", value: artworkURL)]
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyPlexHeaders(to: &request, token: server.accessToken)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (_, response): (Data, URLResponse)
        do {
            ( _, response) = try await session.data(for: request)
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
    }

    /// Uploads image bytes as the item's artwork (`POST /library/metadata/{ids}/{element}` with the binary as the body).
    func uploadArtwork(server: PlexServer, ratingKey: String, element: String = "poster", imageData: Data) async throws {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw PlexAPIError.invalidURL
        }
        components.path = "/library/metadata/\(ratingKey)/\(element)"
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyPlexHeaders(to: &request, token: server.accessToken)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, from: imageData)
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
    }

    /// Execute a typed request against plex.tv.
    func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
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
