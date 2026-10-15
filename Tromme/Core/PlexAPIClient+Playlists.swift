import Foundation

// Playlist and library item management endpoints.
extension PlexAPIClient {
    // MARK: - Playlists

    func getPlaylists(server: PlexServer) async throws -> [PlexPlaylist] {
        // Page through the full list; a single request is capped by the container size,
        // which silently dropped every playlist past the first page.
        let pageSize = 1000
        var allPlaylists: [PlexPlaylist] = []
        var start = 0
        while true {
            let path = "/playlists?X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(pageSize)"
            let response: PlexResponse<PlexPlaylist> = try await serverRequest(server: server, path: path)
            let playlists = response.mediaContainer.metadata ?? []
            allPlaylists.append(contentsOf: playlists)
            start += playlists.count
            if let total = response.mediaContainer.totalSize {
                guard start < total, !playlists.isEmpty else { break }
            } else {
                guard playlists.count == pageSize else { break }
            }
        }
        return allPlaylists
    }

    func getPlaylistItems(server: PlexServer, playlistKey: String) async throws -> [PlexMetadata] {
        let basePath: String
        if playlistKey.hasPrefix("/playlists/") {
            basePath = playlistKey.hasSuffix("/items") ? playlistKey : "\(playlistKey)/items"
        } else {
            basePath = "/playlists/\(playlistKey)/items"
        }

        // The playlist items endpoint doesn't reliably return totalSize, so page
        // sequentially until a page comes back shorter than requested instead of
        // trusting the container's reported total.
        let pageSize = 1000
        var allItems: [PlexMetadata] = []
        var start = 0
        while true {
            let path = "\(basePath)?X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(pageSize)"
            let response: PlexResponse<PlexMetadata> = try await serverRequest(server: server, path: path)
            let items = response.mediaContainer.metadata ?? []
            allItems.append(contentsOf: items)
            guard items.count == pageSize else { break }
            start += pageSize
        }

        return allItems
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
        // The spec's create endpoint takes only `uri`; the title is set afterwards by
        // editing the playlist (PUT /playlists/{playlistId}, same args as metadata edits).
        let queryItems = [URLQueryItem(name: "uri", value: uri)]
        let data = try await rawServerRequest(
            server: server,
            path: "/playlists",
            method: "POST",
            queryItems: queryItems
        )
        do {
            let decoded = try JSONDecoder().decode(PlexResponse<PlexPlaylist>.self, from: data)
            if let playlist = decoded.mediaContainer.metadata?.first {
                guard !trimmedTitle.isEmpty, playlist.title != trimmedTitle else { return playlist }
                try await renamePlaylist(server: server, playlistId: playlist.ratingKey, newTitle: trimmedTitle)
                return PlexPlaylist(
                    ratingKey: playlist.ratingKey,
                    key: playlist.key,
                    type: playlist.type,
                    title: trimmedTitle,
                    summary: playlist.summary,
                    smart: playlist.smart,
                    playlistType: playlist.playlistType,
                    thumb: playlist.thumb,
                    composite: playlist.composite,
                    duration: playlist.duration,
                    leafCount: playlist.leafCount,
                    addedAt: playlist.addedAt,
                    updatedAt: playlist.updatedAt
                )
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

    func renamePlaylist(server: PlexServer, playlistId: String, newTitle: String) async throws {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await rawServerRequest(
            server: server,
            path: "/playlists/\(playlistId)",
            method: "PUT",
            queryItems: [URLQueryItem(name: "title", value: trimmed)]
        )
    }

    /// Repositions a playlist item after another item, or to the front when `afterPlaylistItemID` is nil.
    func movePlaylistItem(
        server: PlexServer,
        playlistId: String,
        playlistItemID: Int,
        afterPlaylistItemID: Int?
    ) async throws {
        let path = "/playlists/\(playlistId)/items/\(playlistItemID)/move"
        if let afterPlaylistItemID {
            _ = try await rawServerRequest(
                server: server,
                path: path,
                method: "PUT",
                queryItems: [URLQueryItem(name: "after", value: String(afterPlaylistItemID))]
            )
        } else {
            _ = try await rawServerRequest(server: server, path: path, method: "PUT")
        }
    }

    func deleteLibraryItem(server: PlexServer, ratingKey: String) async throws {
        _ = try await rawServerRequest(
            server: server,
            path: "/library/metadata/\(ratingKey)",
            method: "DELETE"
        )
    }
}
