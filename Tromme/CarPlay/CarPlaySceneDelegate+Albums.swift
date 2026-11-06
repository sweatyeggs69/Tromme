import CarPlay
import UIKit

@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Albums (A-Z)

    func makeAlbumsList() -> CPListTemplate {
        let template = CPListTemplate(title: "Albums", sections: [])
        loadAlbums(into: template)
        return template
    }

    func loadAlbums(into template: CPListTemplate) {
        guard let server, let sectionId else { return }
        let generation = contentGeneration
        Task {
            let albums: [PlexMetadata]
            do {
                albums = try await client.cachedAlbums(server: server, sectionId: sectionId)
            } catch {
                guard generation == contentGeneration else { return }
                let retry = makeRetryItem(into: template) { [weak self = self] in
                    self?.loadAlbums(into: template)
                }
                template.updateSections([CPListSection(items: [retry])])
                return
            }
            guard generation == contentGeneration else { return }
            populateAlbums(albums, into: template)
        }
    }

    func populateAlbums(_ albums: [PlexMetadata], into template: CPListTemplate) {
        let sections = makeLetterIndex(albums) { [weak self] album in
            let item = CPListItem(text: album.title, detailText: album.parentTitle ?? "")
            item.accessoryType = .disclosureIndicator
            if let self, let server = self.server {
                self.loadArtwork(path: album.thumb, into: item, server: server, client: self.client)
            }
            let ratingKey = album.ratingKey
            let albumTitle = album.title
            item.handler = { [weak self] _, completion in
                self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle)
                completion()
            }
            return item
        }
        template.updateSections(sections)
    }

    // MARK: - Album Tracks

    func showAlbumTracks(albumRatingKey: String, albumTitle: String) {
        guard let server else { return }
        let loadingTemplate = CPListTemplate(title: albumTitle, sections: [])
        interfaceController?.pushTemplate(loadingTemplate, animated: true, completion: nil)
        Task {
            let children: [PlexMetadata]
            do {
                children = try await client.cachedChildren(server: server, ratingKey: albumRatingKey)
            } catch {
                let errItem = CPListItem(text: "Couldn't Load", detailText: "Go back and try again")
                errItem.isEnabled = false
                loadingTemplate.updateSections([CPListSection(items: [errItem])])
                return
            }

            let playableTracks = Array(children.filter { $0.type == "track" })
            guard !playableTracks.isEmpty else { return }

            let playElement = CPListImageRowItemCondensedElement(
                image: (UIImage(systemName: "play.fill") ?? UIImage()).withTintColor(.label, renderingMode: .alwaysOriginal),
                imageShape: .roundedRectangle,
                title: "Play",
                subtitle: nil,
                accessorySymbolName: nil
            )
            let shuffleElement = CPListImageRowItemCondensedElement(
                image: (UIImage(systemName: "shuffle") ?? UIImage()).withTintColor(.label, renderingMode: .alwaysOriginal),
                imageShape: .roundedRectangle,
                title: "Shuffle",
                subtitle: nil,
                accessorySymbolName: nil
            )
            let actionRow = CPListImageRowItem(text: nil, condensedElements: [playElement, shuffleElement], allowsMultipleLines: false)
            actionRow.listImageRowHandler = { [weak self = self] _, index, completion in
                guard let self else { completion(); return }
                if index == 0 {
                    if self.player.isShuffled { self.player.toggleShuffle() }
                } else {
                    if !self.player.isShuffled { self.player.toggleShuffle() }
                }
                self.player.play(tracks: playableTracks, startingAt: 0)
                self.pushNowPlaying()
                completion()
            }

            let trackItems: [CPListTemplateItem] = playableTracks
                .prefix(CPListTemplate.maximumItemCount - 1)
                .enumerated()
                .map { index, track -> CPListItem in
                    let isFavorited = (track.userRating ?? 0) >= 10
                    let numPrefix = track.index.map { "\($0)  " } ?? ""
                    let starPrefix = isFavorited ? "★ " : ""
                    let item = CPListItem(text: "\(numPrefix)\(starPrefix)\(track.title)", detailText: nil)
                    let capturedTracks = playableTracks
                    item.handler = { [weak self = self] _, completion in
                        self?.player.play(tracks: capturedTracks, startingAt: index)
                        self?.pushNowPlaying()
                        completion()
                    }
                    return item
                }

            let template = CPListTemplate(title: albumTitle, sections: [
                CPListSection(items: [actionRow]),
                CPListSection(items: trackItems)
            ])
            interfaceController?.popTemplate(animated: false, completion: nil)
            interfaceController?.pushTemplate(template, animated: false, completion: nil)
        }
    }
}
