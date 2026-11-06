import CarPlay
import UIKit

@MainActor
extension CarPlaySceneDelegate {
    // MARK: - Alphabet Helpers

    func firstLetter(of title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return "#" }
        if CharacterSet.letters.contains(first) {
            return String(trimmed.prefix(1)).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        }
        return "#"
    }

    func letterGroups(_ items: [PlexMetadata]) -> [(letter: String, items: [PlexMetadata])] {
        let grouped = Dictionary(grouping: items) { firstLetter(of: $0.titleSort ?? $0.title) }
        let letters = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return letters.map { letter in
            let sorted = (grouped[letter] ?? []).sorted {
                ($0.titleSort ?? $0.title).localizedCaseInsensitiveCompare($1.titleSort ?? $1.title) == .orderedAscending
            }
            return (letter, sorted)
        }
    }

    func makeLetterIndex(
        _ items: [PlexMetadata],
        makeItem: @escaping @MainActor (PlexMetadata) -> CPListItem
    ) -> [CPListSection] {
        let rows = letterGroups(items).map { group -> CPListItem in
            let row = CPListItem(text: group.letter, detailText: nil)
            row.accessoryType = .disclosureIndicator
            let groupItems = group.items
            let letter = group.letter
            row.handler = { [weak self] _, completion in
                let listItems = groupItems.prefix(CPListTemplate.maximumItemCount).map(makeItem)
                let template = CPListTemplate(title: letter, sections: [CPListSection(items: Array(listItems))])
                self?.interfaceController?.pushTemplate(template, animated: true, completion: nil)
                completion()
            }
            return row
        }
        return [CPListSection(items: rows)]
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

        if let startAt {
            player.play(tracks: tracks, startingAt: startAt)
            pushNowPlaying()
        }
    }

    // MARK: - Album and Artist Lists

    func showAlbumList(title: String, albums: [PlexMetadata]) {
        guard let server else { return }
        let items = albums.map { album -> CPListItem in
            let item = CPListItem(text: album.title, detailText: album.parentTitle ?? "")
            item.accessoryType = .disclosureIndicator
            loadArtwork(path: album.thumb, into: item, server: server, client: client)
            let ratingKey = album.ratingKey
            let albumTitle = album.title
            item.handler = { [weak self] _, completion in
                self?.showAlbumTracks(albumRatingKey: ratingKey, albumTitle: albumTitle)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    func showArtistList(title: String, artists: [PlexMetadata]) {
        guard let server else { return }
        let items = artists.prefix(CPListTemplate.maximumItemCount).map { artist -> CPListItem in
            let item = CPListItem(text: artist.title, detailText: nil)
            item.accessoryType = .disclosureIndicator
            loadArtwork(path: artist.thumb, into: item, server: server, client: client)
            item.handler = { [weak self] _, completion in
                self?.showArtistAlbums(artist: artist)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
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
        let limited = Array(items.prefix(CPMaximumNumberOfGridImages))
        return await makeImageRow(
            title: title,
            thumbPaths: limited.map { $0.thumb ?? $0.parentThumb },
            elementTitles: limited.map { elementTitle?($0) },
            elementSubtitles: limited.map { elementSubtitle?($0) },
            server: server,
            client: client,
            onImageSelect: onImageSelect,
            onRowSelect: onRowSelect
        )
    }

    func makeImageRow(
        title: String,
        thumbPaths: [String?],
        elementTitles: [String?],
        elementSubtitles: [String?],
        server: PlexServer,
        client: PlexAPIClient,
        onImageSelect: @escaping @MainActor (Int) -> Void,
        onRowSelect: @escaping @MainActor () -> Void
    ) async -> CPListImageRowItem {
        let placeholder = UIImage(systemName: "music.note") ?? UIImage()

        var loadedImages: [Int: UIImage] = [:]
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (i, thumbPath) in thumbPaths.enumerated() {
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

        let elements = thumbPaths.indices.map { i in
            CPListImageRowItemRowElement(
                image: loadedImages[i] ?? placeholder,
                title: elementTitles[i],
                subtitle: elementSubtitles[i]
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
