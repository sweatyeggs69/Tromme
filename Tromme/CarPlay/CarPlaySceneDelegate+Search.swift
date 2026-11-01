import CarPlay
import UIKit

@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Search

    func makeSearchList() -> CPListTemplate {
        let item = CPListItem(text: "Search", detailText: nil, image: UIImage(systemName: "magnifyingglass"))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.showSearch()
            completion()
        }
        return CPListTemplate(title: "Search", sections: [CPListSection(items: [item])])
    }

    func showSearch() {
        let template = CPSearchTemplate()
        template.delegate = self
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    func searchResultItems(for query: String) async -> [CPListItem] {
        guard let server, !query.isEmpty,
              let hubs = try? await client.search(server: server, query: query, sectionId: sectionId, limit: 6) else { return [] }
        let supported: Set<String> = ["artist", "album", "track", "playlist"]
        return hubs.flatMap { $0.metadata ?? [] }
            .filter { supported.contains($0.type ?? "") }
            .map { metadata in
                let detail: String? = switch metadata.type {
                case "artist": "Artist"
                case "album": metadata.parentTitle.map { "Album · \($0)" } ?? "Album"
                case "playlist": "Playlist"
                default: metadata.artistDisplayName
                }
                let item = CPListItem(text: metadata.title, detailText: detail)
                item.userInfo = metadata
                loadArtwork(path: metadata.thumb ?? metadata.parentThumb, into: item, server: server, client: client)
                return item
            }
    }

    func openSearchResult(_ metadata: PlexMetadata) {
        switch metadata.type {
        case "artist":
            showArtistAlbums(artist: metadata)
        case "album":
            showAlbumTracks(
                albumRatingKey: metadata.ratingKey,
                albumTitle: metadata.title,
                artistName: metadata.parentTitle,
                albumThumb: metadata.thumb
            )
        case "playlist":
            showPlaylistTracks(playlistKey: metadata.key ?? metadata.ratingKey, playlistTitle: metadata.title)
        default:
            player.play(tracks: [metadata], startingAt: 0)
            pushNowPlaying()
        }
    }
}

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            completion(await searchResultItems(for: searchText))
        }
    }

    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        nonisolated(unsafe) let completion = completionHandler
        nonisolated(unsafe) let selected = item
        Task { @MainActor in
            if let metadata = selected.userInfo as? PlexMetadata {
                openSearchResult(metadata)
            }
            completion()
        }
    }
}
