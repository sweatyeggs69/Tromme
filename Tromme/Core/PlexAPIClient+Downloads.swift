import Foundation

// Server-side transcoded downloads through the documented /downloadQueue family.
extension PlexAPIClient {
    static let spaceSaverBitrateKbps = 256
    static let spaceSaverFileExtension = "m4a"

    private static let profileExtraSpaceSaver =
        "add-transcode-target(type=musicProfile&context=static&protocol=http&container=mp4&audioCodec=aac)"

    private static let queueItemPollInterval: Duration = .seconds(2)
    private static let queueItemTimeout: TimeInterval = 900

    private struct QueueEnvelope: Decodable {
        let mediaContainer: Container

        struct Container: Decodable {
            let downloadQueue: [Queue]?
            let addedQueueItems: [AddedItem]?
            let downloadQueueItem: [Item]?

            enum CodingKeys: String, CodingKey {
                case downloadQueue = "DownloadQueue"
                case addedQueueItems = "AddedQueueItems"
                case downloadQueueItem = "DownloadQueueItem"
            }
        }

        struct Queue: Decodable { let id: Int }
        struct AddedItem: Decodable { let id: Int }
        struct Item: Decodable {
            let status: String?
        }

        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    /// Transcodes a track on the server to the Space Saver target (AAC) and returns the
    /// downloaded temp file. The queue item is removed from the server afterwards.
    func transcodedDownload(server: PlexServer, ratingKey: String) async throws -> URL {
        let queue = try await queueRequest(server: server, path: "/downloadQueue", method: "POST")
        guard let queueID = queue.mediaContainer.downloadQueue?.first?.id else {
            throw PlexAPIError.serverError(-1)
        }

        let added = try await queueRequest(
            server: server,
            path: "/downloadQueue/\(queueID)/add",
            method: "POST",
            query: [
                URLQueryItem(name: "keys", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "mediaIndex", value: "0"),
                URLQueryItem(name: "partIndex", value: "0"),
                URLQueryItem(name: "directPlay", value: "0"),
                URLQueryItem(name: "directStream", value: "0"),
                URLQueryItem(name: "directStreamAudio", value: "0"),
                URLQueryItem(name: "musicBitrate", value: "\(Self.spaceSaverBitrateKbps)"),
            ]
        )
        guard let itemID = added.mediaContainer.addedQueueItems?.first?.id else {
            throw PlexAPIError.serverError(-1)
        }

        do {
            try await waitForQueueItem(server: server, queueID: queueID, itemID: itemID)
            let url = try await downloadQueueMedia(server: server, queueID: queueID, itemID: itemID)
            removeQueueItem(server: server, queueID: queueID, itemID: itemID)
            return url
        } catch {
            removeQueueItem(server: server, queueID: queueID, itemID: itemID)
            throw error
        }
    }

    private func waitForQueueItem(server: PlexServer, queueID: Int, itemID: Int) async throws {
        let deadline = Date().addingTimeInterval(Self.queueItemTimeout)
        while true {
            try Task.checkCancellation()
            let response = try await queueRequest(
                server: server,
                path: "/downloadQueue/\(queueID)/items/\(itemID)",
                method: "GET"
            )
            switch response.mediaContainer.downloadQueueItem?.first?.status {
            case "available": return
            case "error", "expired": throw PlexAPIError.serverError(-2)
            default: break
            }
            guard Date() < deadline else { throw PlexAPIError.serverError(-3) }
            try await Task.sleep(for: Self.queueItemPollInterval)
        }
    }

    private func downloadQueueMedia(server: PlexServer, queueID: Int, itemID: Int) async throws -> URL {
        let request = try makeQueueRequest(
            server: server,
            path: "/downloadQueue/\(queueID)/item/\(itemID)/media",
            method: "GET"
        )
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PlexAPIError.networkError(error)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode < 400 else { throw PlexAPIError.serverError(statusCode) }
        return tempURL
    }

    /// Frees the transcoded copy on the server. Fire and forget so it also runs after cancellation.
    private func removeQueueItem(server: PlexServer, queueID: Int, itemID: Int) {
        guard let request = try? makeQueueRequest(
            server: server,
            path: "/downloadQueue/\(queueID)/items/\(itemID)",
            method: "DELETE"
        ) else { return }
        let session = session
        Task.detached { _ = try? await session.data(for: request) }
    }

    private func queueRequest(
        server: PlexServer,
        path: String,
        method: String,
        query: [URLQueryItem] = []
    ) async throws -> QueueEnvelope {
        let request = try makeQueueRequest(server: server, path: path, method: method, query: query)
        return try await retryingRequest {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await self.session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PlexAPIError.networkError(error)
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard statusCode < 400 else { throw PlexAPIError.serverError(statusCode) }
            do {
                return try JSONDecoder().decode(QueueEnvelope.self, from: data)
            } catch {
                throw PlexAPIError.decodingError(error, path: path)
            }
        }
    }

    private func makeQueueRequest(
        server: PlexServer,
        path: String,
        method: String,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard let baseURL = server.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PlexAPIError.invalidURL
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyPlexHeaders(to: &request, token: server.accessToken)
        request.setValue("Generic", forHTTPHeaderField: "X-Plex-Client-Profile-Name")
        request.setValue(Self.profileExtraSpaceSaver, forHTTPHeaderField: "X-Plex-Client-Profile-Extra")
        return request
    }
}
