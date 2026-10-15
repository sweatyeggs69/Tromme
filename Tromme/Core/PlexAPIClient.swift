import Foundation

/// Status of an item in the Plex `/downloadQueue` (Download Queue API).
enum DownloadQueueItemStatus: String, Decodable, Sendable {
    case deciding, waiting, processing, available, error, expired
}

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

struct PlexMetadataImageResponse: Decodable, Sendable {
    let mediaContainer: PlexMetadataImageContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

struct PlexMetadataImageContainer: Decodable, Sendable {
    let metadata: [PlexMetadataImageItem]?

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
    }
}

struct PlexMetadataImageItem: Decodable, Sendable {
    let image: [PlexImageResource]?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
    }
}

struct PlexArtworkResourceResponse: Decodable, Sendable {
    let mediaContainer: PlexArtworkResourceContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

struct PlexArtworkResourceContainer: Decodable, Sendable {
    let image: [PlexImageResource]?
    let metadata: [PlexArtworkResourceMetadata]?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case metadata = "Metadata"
    }
}

struct PlexArtworkResourceMetadata: Decodable, Sendable {
    let key: String?
    let url: String?
    let thumb: String?
    let provider: String?
    let type: String?
    let selected: Bool?
    let width: Int?
    let height: Int?

    var asImageResource: PlexImageResource {
        PlexImageResource(
            key: key,
            provider: provider,
            type: type,
            url: url,
            thumb: thumb,
            selected: selected,
            width: width,
            height: height
        )
    }

    enum CodingKeys: String, CodingKey {
        case key, url, thumb, provider, type, selected, width, height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try? c.decodeIfPresent(String.self, forKey: .key)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        selected = Self.decodeFlexibleBool(from: c, forKey: .selected)
        width = Self.decodeFlexibleInt(from: c, forKey: .width)
        height = Self.decodeFlexibleInt(from: c, forKey: .height)
    }

    private static func decodeFlexibleInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func decodeFlexibleBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

private final class ArtworkXMLParserDelegate: NSObject, XMLParserDelegate {
    var images: [PlexImageResource] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let supportedElements: Set<String> = ["Image", "Photo", "Poster"]
        guard supportedElements.contains(elementName) else { return }

        let width = attributeDict["width"].flatMap(Int.init)
        let height = attributeDict["height"].flatMap(Int.init)
        let selected = attributeDict["selected"].flatMap { $0 == "1" ? true : ($0 == "0" ? false : nil) }
        let image = PlexImageResource(
            key: attributeDict["key"],
            provider: attributeDict["provider"],
            type: attributeDict["type"],
            url: attributeDict["url"],
            thumb: attributeDict["thumb"],
            selected: selected,
            width: width,
            height: height
        )
        images.append(image)
    }
}

struct DownloadQueueResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        struct Entry: Decodable, Sendable { let id: Int }
        let downloadQueue: [Entry]?
        enum CodingKeys: String, CodingKey { case downloadQueue = "DownloadQueue" }
    }
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

struct DownloadQueueAddResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        struct AddedItem: Decodable, Sendable { let id: Int }
        let addedQueueItems: [AddedItem]?
        enum CodingKeys: String, CodingKey { case addedQueueItems = "AddedQueueItems" }
    }
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

struct DownloadQueueItemsResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let status: DownloadQueueItemStatus
        }
        let items: [Item]?
        enum CodingKeys: String, CodingKey { case items = "DownloadQueueItem" }
    }
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}
