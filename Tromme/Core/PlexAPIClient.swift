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

@Observable
final class PlexAPIClient: Sendable {
    // Required Plex identification headers (per API spec)
    static let clientIdentifier = "com.kylemcclain.Tromme"
    static let product = "Tromme"
    static let version = "1.0.0"
    static let platform = "iOS"
    static let platformVersion = ProcessInfo.processInfo.operatingSystemVersionString
    static let device = "iPhone"
    static let deviceName = "Tromme iOS"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
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
        var path = "/library/sections/\(sectionId)/all"
        if let type {
            path += "?type=\(type)"
        }
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
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: "/playlists/\(playlistKey)/items"
        )
        return response.mediaContainer.metadata ?? []
    }

    // MARK: - Playback

    /// Mark an item as played (scrobble). Per API spec:
    /// - `identifier`: required, the media provider identifier
    /// - `key`: the ratingKey of the item
    func scrobble(server: PlexServer, ratingKey: String) async throws {
        let path = "/:/scrobble?identifier=com.plexapp.plugins.library&key=\(ratingKey)"
        _ = try await rawServerRequest(server: server, path: path, method: "PUT")
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidURL
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw PlexAPIError.unauthorized }
            throw PlexAPIError.serverError(http.statusCode)
        }
        return data
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
