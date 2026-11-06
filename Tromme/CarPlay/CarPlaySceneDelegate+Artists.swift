import CarPlay
import UIKit

@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Artists (A-Z)

    func makeArtistsList() -> CPListTemplate {
        let template = CPListTemplate(title: "Artists", sections: [])
        loadArtists(into: template)
        return template
    }

    func loadArtists(into template: CPListTemplate) {
        guard let server, let sectionId else { return }
        let generation = contentGeneration
        Task {
            let artists: [PlexMetadata]
            do {
                artists = try await client.cachedArtists(server: server, sectionId: sectionId)
            } catch {
                guard generation == contentGeneration else { return }
                let retry = makeRetryItem(into: template) { [weak self = self] in
                    self?.loadArtists(into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            guard generation == contentGeneration else { return }
            populateArtists(artists, into: template)
        }
    }

    func populateArtists(_ artists: [PlexMetadata], into template: CPListTemplate) {
        let sections = makeLetterIndex(artists) { [weak self] artist in
            let item = CPListItem(text: artist.title, detailText: nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showArtistAlbums(artist: artist)
                completion()
            }
            return item
        }
        template.updateSections(sections)
    }

    func showArtistAlbums(artist: PlexMetadata) {
        guard let server, let sectionId else { return }
        let template = CPListTemplate(title: artist.title, sections: [])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        loadArtistAlbums(artist: artist, server: server, sectionId: sectionId, client: client, into: template)
    }

    func loadArtistAlbums(artist: PlexMetadata, server: PlexServer, sectionId: String, client: PlexAPIClient, into template: CPListTemplate) {
        let artistName = artist.title
        Task {
            let releases: [PlexMetadata]
            do {
                releases = try await client.cachedArtistReleases(server: server, sectionId: sectionId, artist: artist)
            } catch {
                let retry = makeRetryItem(into: template) { [weak self = self] in
                    self?.loadArtistAlbums(artist: artist, server: server, sectionId: sectionId, client: client, into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            let albums = releases.filter { $0.type == "album" }
            guard !albums.isEmpty else {
                template.updateSections([])
                return
            }

            let shuffleItem = CPListItem(text: "Shuffle", detailText: "\(albums.count) albums", image: UIImage(systemName: "shuffle"))
            shuffleItem.handler = { [weak self = self] _, completion in
                Task {
                    let allTracks = await withTaskGroup(of: [PlexMetadata].self) { group in
                        for album in albums {
                            let key = album.ratingKey
                            let updatedAt = album.updatedAt
                            group.addTask {
                                do {
                                    return try await client.cachedChildren(server: server, ratingKey: key, updatedAt: updatedAt)
                                } catch {
                                    #if DEBUG
                                    print("[CarPlay] Failed to load tracks for album \(key): \(error)")
                                    #endif
                                    return []
                                }
                            }
                        }
                        var result: [PlexMetadata] = []
                        for await tracks in group {
                            result.append(contentsOf: tracks.filter { $0.type == "track" })
                        }
                        return result
                    }
                    guard !allTracks.isEmpty, let self else {
                        completion()
                        return
                    }
                    if !self.player.isShuffled { self.player.toggleShuffle() }
                    self.player.play(tracks: allTracks, startingAt: 0)
                    self.pushNowPlaying()
                    completion()
                }
            }

            let albumItems: [CPListTemplateItem] = albums.prefix(CPListTemplate.maximumItemCount - 1).map { album -> CPListItem in
                let item = CPListItem(text: album.title, detailText: album.releaseYear)
                item.accessoryType = .disclosureIndicator
                loadArtwork(path: album.thumb, into: item, server: server, client: client)
                let ratingKey = album.ratingKey
                let albumTitle = album.title
                let albumThumb = album.thumb
                let albumYear = album.releaseYear
                item.handler = { [weak self = self] _, completion in
                    self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle, artistName: artistName, albumThumb: albumThumb, releaseYear: albumYear)
                    completion()
                }
                return item
            }

            var allItems: [CPListTemplateItem] = [shuffleItem]
            allItems.append(contentsOf: albumItems)
            template.updateSections([CPListSection(items: allItems)])
        }
    }
}
