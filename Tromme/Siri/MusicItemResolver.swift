import Foundation

enum MusicItemResolverError: Error {
    case notSignedIn
    case nothingFound
}

@MainActor
enum MusicItemResolver {
    private static var context: (server: PlexServer, sectionId: String?, client: PlexAPIClient)? {
        let connection = AppContext.shared.serverConnection
        guard let server = connection.currentServer else { return nil }
        return (server, connection.currentLibrarySectionId, AppContext.shared.plexClient)
    }

    static func search(_ query: String, limit: Int = 8) async throws -> [MusicItemEntity] {
        guard let context else { throw MusicItemResolverError.notSignedIn }
        let hubs = try await context.client.search(server: context.server, query: query, sectionId: context.sectionId, limit: limit)
        return hubs.flatMap { $0.metadata ?? [] }.compactMap(entity(from:))
    }

    static func entities(for ids: [String]) async -> [MusicItemEntity] {
        guard let context else { return [] }
        var results: [MusicItemEntity] = []
        for id in ids {
            guard let separator = id.firstIndex(of: ":"),
                  let kind = MusicItemKind(rawValue: String(id[..<separator])) else { continue }
            let key = String(id[id.index(after: separator)...])
            if kind == .playlist {
                let playlists = (try? await context.client.cachedPlaylists(server: context.server)) ?? []
                if let playlist = playlists.first(where: { $0.ratingKey == key }) {
                    results.append(MusicItemEntity(kind: .playlist, ratingKey: key, title: playlist.title, subtitle: nil))
                }
            } else if let metadata = try? await context.client.cachedMetadata(server: context.server, ratingKey: key),
                      let entity = entity(from: metadata) {
                results.append(entity)
            }
        }
        return results
    }

    static func tracks(for item: MusicItemEntity) async throws -> [PlexMetadata] {
        guard let context, let kind = item.kind else { throw MusicItemResolverError.notSignedIn }
        let tracks: [PlexMetadata]
        switch kind {
        case .track:
            tracks = try await context.client.cachedMetadata(server: context.server, ratingKey: item.ratingKey).map { [$0] } ?? []
        case .album:
            tracks = try await context.client.getAlbumTracks(server: context.server, ratingKey: item.ratingKey)
        case .artist:
            guard let sectionId = context.sectionId else { throw MusicItemResolverError.notSignedIn }
            tracks = try await context.client.getArtistTracks(server: context.server, sectionId: sectionId, artistRatingKey: item.ratingKey)
        case .playlist:
            tracks = try await context.client.getPlaylistItems(server: context.server, playlistKey: item.ratingKey)
        }
        guard !tracks.isEmpty else { throw MusicItemResolverError.nothingFound }
        return tracks
    }

    private static func entity(from metadata: PlexMetadata) -> MusicItemEntity? {
        switch metadata.type {
        case "artist":
            return MusicItemEntity(kind: .artist, ratingKey: metadata.ratingKey, title: metadata.title, subtitle: nil)
        case "album":
            return MusicItemEntity(kind: .album, ratingKey: metadata.ratingKey, title: metadata.title, subtitle: metadata.parentTitle)
        case "track":
            return MusicItemEntity(kind: .track, ratingKey: metadata.ratingKey, title: metadata.title, subtitle: metadata.artistDisplayName)
        case "playlist":
            return MusicItemEntity(kind: .playlist, ratingKey: metadata.ratingKey, title: metadata.title, subtitle: nil)
        default:
            return nil
        }
    }
}
