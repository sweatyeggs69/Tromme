import Foundation

// Library, metadata, artwork, hubs and search endpoints.
extension PlexAPIClient {
    // MARK: - Library Endpoints

    func getLibrarySections(server: PlexServer) async throws -> [LibrarySection] {
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: "/library/sections/all"
        )
        return response.mediaContainer.directory ?? []
    }

    func getLibraryContents(server: PlexServer, sectionId: String, type: Int? = nil) async throws -> [PlexMetadata] {
        var allItems: [PlexMetadata] = []
        try await streamLibraryContents(server: server, sectionId: sectionId, type: type) { page in
            allItems.append(contentsOf: page)
        }
        return allItems
    }

    /// Pages through `/library/sections/{id}/all`, handing each page to `onPage` in order
    /// as it arrives so callers (the library sync) can persist incrementally instead of
    /// holding an entire library in memory.
    func streamLibraryContents(
        server: PlexServer,
        sectionId: String,
        type: Int? = nil,
        onPage: (_ page: [PlexMetadata]) async throws -> Void
    ) async throws {
        let pageSize = 1000
        let typeParam = type.map { "&type=\($0)" } ?? ""

        func fetchPage(start: Int) async throws -> PlexResponse<PlexMetadata> {
            let path = "/library/sections/\(sectionId)/all?X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(pageSize)\(typeParam)"
            #if DEBUG
            let began = ContinuousClock.now
            print("[LibraryFetch] type \(type ?? 0) start \(start): requesting from \(server.baseURL?.host() ?? "?")")
            defer { print("[LibraryFetch] type \(type ?? 0) start \(start): returned after \(ContinuousClock.now - began)") }
            #endif
            return try await retryingRequest {
                try await self.serverRequest(server: server, path: path)
            }
        }

        // Fetch first page to discover the total item count
        let firstResponse = try await fetchPage(start: 0)
        let firstPage = firstResponse.mediaContainer.metadata ?? []
        try await onPage(firstPage)
        let total = firstResponse.mediaContainer.totalSize ?? firstPage.count
        guard total > firstPage.count else { return }

        // Remaining pages: at most 10 in flight, each handed to `onPage` the moment it
        // arrives (page order doesn't matter to the store) so progress is steady and only
        // a few pages are ever held in memory.
        let pageStarts = Array(stride(from: pageSize, to: total, by: pageSize))
        try await withThrowingTaskGroup(of: [PlexMetadata].self) { group in
            var iterator = pageStarts.makeIterator()
            func addNext() {
                guard let start = iterator.next() else { return }
                group.addTask {
                    try await fetchPage(start: start).mediaContainer.metadata ?? []
                }
            }
            for _ in 0..<10 { addNext() }
            while let page = try await group.next() {
                try await onPage(page)
                addNext()
            }
        }
    }

    /// Fetch tracks considered favorites by Plex (typically user-rated 4+ stars).
    func getFavoriteTracks(server: PlexServer, sectionId: String, minUserRating: Int = 4) async throws -> [PlexMetadata] {
        let path = "/library/sections/\(sectionId)/all?type=10&track.userRating>=\(minUserRating)"
        let response: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: path)
        return response.mediaContainer.metadata ?? []
    }

    /// Fetch all tracks for a specific artist using server-side filtering.
    /// Avoids loading the full library just to filter by artist.
    func getArtistTracks(server: PlexServer, sectionId: String, artistRatingKey: String) async throws -> [PlexMetadata] {
        let pageSize = 1000
        let firstPath = "/library/sections/\(sectionId)/all?type=10&artist.id=\(artistRatingKey)&X-Plex-Container-Start=0&X-Plex-Container-Size=\(pageSize)"
        let firstResponse: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: firstPath)
        var allItems = firstResponse.mediaContainer.metadata ?? []
        let total = firstResponse.mediaContainer.totalSize ?? allItems.count
        guard total > allItems.count else { return allItems }

        let pageStarts = Array(stride(from: pageSize, to: total, by: pageSize))
        for batchOffset in stride(from: 0, to: pageStarts.count, by: 10) {
            let batch = pageStarts[batchOffset..<min(batchOffset + 10, pageStarts.count)]
            let batchItems = try await withThrowingTaskGroup(of: [PlexMetadata].self) { group in
                for start in batch {
                    let path = "/library/sections/\(sectionId)/all?type=10&artist.id=\(artistRatingKey)&X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(pageSize)"
                    group.addTask {
                        let response: PlexResponse<PlexMetadata> = try await self.serverRequest(server: server, path: path)
                        return response.mediaContainer.metadata ?? []
                    }
                }
                var results: [PlexMetadata] = []
                for try await items in group { results.append(contentsOf: items) }
                return results
            }
            allItems.append(contentsOf: batchItems)
        }
        return allItems
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

    /// Tracks of an album. Endpoint: GET /library/metadata/{ids}/allLeaves.
    func getAlbumTracks(server: PlexServer, ratingKey: String) async throws -> [PlexMetadata] {
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: "/library/metadata/\(ratingKey)/allLeaves"
        )
        return response.mediaContainer.metadata ?? []
    }

    /// Albums of an artist. Endpoint: GET /library/sections/{sectionId}/all?type=9&artist.id=.
    func getArtistAlbums(server: PlexServer, sectionId: String, artistRatingKey: String) async throws -> [PlexMetadata] {
        let path = "/library/sections/\(sectionId)/all?type=9&artist.id=\(artistRatingKey)"
        let response: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: path)
        return response.mediaContainer.metadata ?? []
    }

    func getMetadata(server: PlexServer, ratingKey: String) async throws -> PlexMetadata? {
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: "/library/metadata/\(ratingKey)"
        )
        return response.mediaContainer.metadata?.first
    }

    /// One request for several items: the path takes a comma-separated list of ids.
    func getMetadata(server: PlexServer, ratingKeys: [String]) async throws -> [PlexMetadata] {
        guard !ratingKeys.isEmpty else { return [] }
        let response: PlexResponse<PlexMetadata> = try await serverRequest(
            server: server,
            path: "/library/metadata/\(ratingKeys.joined(separator: ","))"
        )
        return response.mediaContainer.metadata ?? []
    }

    func getMetadataArtworkOptions(server: PlexServer, ratingKey: String) async throws -> [PlexImageResource] {
        let response: PlexMetadataImageResponse = try await serverRequest(
            server: server,
            path: "/library/metadata/\(ratingKey)"
        )
        let metadataImages = response.mediaContainer.metadata?.first?.image ?? []
        let posterLike = metadataImages.filter { image in
            guard let type = image.type?.lowercased() else { return false }
            return type == "coverposter" || type == "poster"
        }
        return posterLike.isEmpty ? metadataImages : posterLike
    }

    func getArtworkResources(server: PlexServer, ratingKey: String, element: String = "posters") async throws -> [PlexImageResource] {
        let path = "/library/metadata/\(ratingKey)/\(element)"
        let queryItems = [URLQueryItem(name: "includeExternalMedia", value: "1")]
        let data = try await rawServerRequest(server: server, path: path, method: "GET", queryItems: queryItems)

        do {
            let response = try JSONDecoder().decode(PlexArtworkResourceResponse.self, from: data)
            if let directImages = response.mediaContainer.image, !directImages.isEmpty {
                return directImages
            }

            if let metadataItems = response.mediaContainer.metadata, !metadataItems.isEmpty {
                return metadataItems.map(\.asImageResource)
            }

            return []
        } catch {
            // Some PMS versions still return XML for this endpoint.
            let xmlImages = parseArtworkResourcesXML(data)
            if !xmlImages.isEmpty {
                return xmlImages
            }
            throw PlexAPIError.decodingError(error, path: path)
        }
    }

    func setArtworkResource(server: PlexServer, ratingKey: String, element: String = "poster", artworkURL: String) async throws {
        let candidateElements: [String]
        if element == "poster" {
            candidateElements = ["posters", "poster", "thumb", "thumbs", "art", "arts"]
        } else {
            candidateElements = [element, "poster", "thumb", "posters", "thumbs", "art", "arts"]
        }
        let candidateMethods = ["POST", "PUT"]
        var lastError: Error?

        for candidateElement in candidateElements {
            for method in candidateMethods {
                do {
                    try await setArtworkResource(
                        server: server,
                        ratingKey: ratingKey,
                        element: candidateElement,
                        artworkURL: artworkURL,
                        method: method
                    )
                    return
                } catch let error as PlexAPIError {
                    switch error {
                    case .serverError(400), .serverError(404), .serverError(406):
                        lastError = error
                        continue
                    default:
                        throw error
                    }
                } catch {
                    throw error
                }
            }
        }

        if let lastError {
            throw lastError
        } else {
            throw PlexAPIError.serverError(404)
        }
    }


    // MARK: - Related Hubs

    /// Returns the "You May Also Like" and other related hubs for a given metadata item.
    func getRelatedHubs(server: PlexServer, ratingKey: String) async throws -> [Hub] {
        let data = try await rawServerRequest(
            server: server,
            path: "/hubs/metadata/\(ratingKey)/related",
            method: "GET",
            queryItems: []
        )
        let response = try JSONDecoder().decode(PlexResponse<PlexMetadata>.self, from: data)
        return response.mediaContainer.hub ?? []
    }

    // MARK: - Search

    func search(server: PlexServer, query: String, sectionId: String? = nil, limit: Int = 20) async throws -> [Hub] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let sectionId {
            queryItems.append(URLQueryItem(name: "sectionId", value: sectionId))
        }

        let data = try await rawServerRequest(
            server: server,
            path: "/hubs/search",
            method: "GET",
            queryItems: queryItems
        )
        let response = try JSONDecoder().decode(PlexResponse<PlexMetadata>.self, from: data)
        return response.mediaContainer.hub ?? []
    }
}
