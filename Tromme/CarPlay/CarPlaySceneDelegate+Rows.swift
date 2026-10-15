import CarPlay
import UIKit

// CarPlay Rows templates.
@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Alphabet Helpers

    func firstLetter(of title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return "#" }
        if CharacterSet.letters.contains(first) {
            return String(trimmed.prefix(1)).uppercased()
        }
        return "#"
    }

    // MARK: - Track List (with Shuffle)

    func showTrackList(title: String, tracks: [PlexMetadata], startAt: Int? = nil, showActions: Bool = true) {
        let capturedTracks = tracks

        var actionRow: CPListImageRowItem?
        if showActions {
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
            let row = CPListImageRowItem(text: nil, condensedElements: [playElement, shuffleElement], allowsMultipleLines: false)
            row.listImageRowHandler = { [weak self] _, index, completion in
                guard let self else { completion(); return }
                if index == 0 {
                    if self.player.isShuffled { self.player.toggleShuffle() }
                } else {
                    if !self.player.isShuffled { self.player.toggleShuffle() }
                }
                self.player.play(tracks: capturedTracks, startingAt: 0)
                self.pushNowPlaying()
                completion()
            }
            actionRow = row
        }

        let maxTrackItems = CPListTemplate.maximumItemCount - (showActions ? 1 : 0)
        let trackItems: [CPListTemplateItem] = tracks.prefix(maxTrackItems).enumerated().map { index, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artistDisplayName)
            if let server {
                loadArtwork(path: track.thumb ?? track.parentThumb, into: item, server: server, client: client)
            }
            item.handler = { [weak self] _, completion in
                self?.player.play(tracks: capturedTracks, startingAt: index)
                self?.pushNowPlaying()
                completion()
            }
            return item
        }

        var allItems: [CPListTemplateItem] = actionRow.map { [$0] } ?? []
        allItems.append(contentsOf: trackItems)
        let template = CPListTemplate(title: title, sections: [CPListSection(items: allItems)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)

        // If called from an image row tap, auto-play that track
        if let startAt {
            player.play(tracks: tracks, startingAt: startAt)
            pushNowPlaying()
        }
    }

    // MARK: - Recently Added List

    func showRecentlyAddedList(_ albums: [PlexMetadata]) {
        guard let server else { return }
        let items = albums.map { album -> CPListItem in
            let item = CPListItem(text: album.title, detailText: album.parentTitle ?? "")
            item.accessoryType = .disclosureIndicator
            loadArtwork(path: album.thumb, into: item, server: server, client: client)
            let ratingKey = album.ratingKey
            let albumTitle = album.title
            let artistName = album.parentTitle
            let albumThumb = album.thumb
            let albumYear = album.releaseYear
            item.handler = { [weak self] _, completion in
                self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle, artistName: artistName, albumThumb: albumThumb, releaseYear: albumYear)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Recently Added", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Image Row

    func makeImageRow(
        title: String,
        items: [PlexMetadata],
        server: PlexServer,
        client: PlexAPIClient,
        elementTitle: ((PlexMetadata) -> String?)? = nil,
        elementSubtitle: ((PlexMetadata) -> String?)? = nil,
        onImageSelect: @escaping @MainActor (Int) -> Void,
        onRowSelect: @escaping @MainActor () -> Void
    ) async -> CPListImageRowItem {
        let maxImages = CPMaximumNumberOfGridImages
        let limited = Array(items.prefix(maxImages))
        let placeholder = UIImage(systemName: "music.note") ?? UIImage()

        // Load artwork in parallel
        var loadedImages: [Int: UIImage] = [:]
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (i, metadata) in limited.enumerated() {
                let thumbPath = metadata.thumb ?? metadata.parentThumb
                group.addTask {
                    guard let url = client.artworkURL(server: server, path: thumbPath, width: 300, height: 300) else {
                        return (i, nil)
                    }
                    return (i, await ImageCache.shared.image(for: url, targetPixelSize: 300))
                }
            }
            for await (i, img) in group {
                if let img { loadedImages[i] = img }
            }
        }

        let elements = limited.enumerated().map { i, metadata -> CPListImageRowItemRowElement in
            CPListImageRowItemRowElement(
                image: loadedImages[i] ?? placeholder,
                title: elementTitle?(metadata),
                subtitle: elementSubtitle?(metadata)
            )
        }

        let row = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
        row.listImageRowHandler = { _, index, completion in
            onImageSelect(index)
            completion()
        }
        row.handler = { _, completion in
            onRowSelect()
            completion()
        }

        return row
    }

    // MARK: - Condensed Image Row (artwork left, title/artist right, 2-wide grid)

    func makeCondensedImageRow(
        title: String,
        items: [PlexMetadata],
        server: PlexServer,
        client: PlexAPIClient,
        elementTitle: (PlexMetadata) -> String?,
        elementSubtitle: (PlexMetadata) -> String?,
        onElementSelect: @escaping @MainActor (Int) -> Void,
        onHeaderSelect: @escaping @MainActor () -> Void
    ) async -> CPListImageRowItem {
        let placeholder = UIImage(systemName: "music.note") ?? UIImage()

        var loadedImages: [Int: UIImage] = [:]
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (i, metadata) in items.enumerated() {
                let thumbPath = metadata.thumb ?? metadata.parentThumb
                group.addTask {
                    guard let url = client.artworkURL(server: server, path: thumbPath, width: 300, height: 300) else {
                        return (i, nil)
                    }
                    return (i, await ImageCache.shared.image(for: url, targetPixelSize: 300))
                }
            }
            for await (i, img) in group {
                if let img { loadedImages[i] = img }
            }
        }

        let elements = items.enumerated().map { i, metadata -> CPListImageRowItemCondensedElement in
            CPListImageRowItemCondensedElement(
                image: loadedImages[i] ?? placeholder,
                imageShape: .roundedRectangle,
                title: elementTitle(metadata) ?? "",
                subtitle: elementSubtitle(metadata),
                accessorySymbolName: nil
            )
        }

        let row = CPListImageRowItem(text: title, condensedElements: elements, allowsMultipleLines: true)
        row.listImageRowHandler = { _, index, completion in
            onElementSelect(index)
            completion()
        }
        row.handler = { _, completion in
            onHeaderSelect()
            completion()
        }
        return row
    }
}
