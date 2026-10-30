import Foundation

enum LibraryPrefetcher {
    private static let artworkPixelSize = 640

    private static var canPrefetch: Bool {
        NetworkStatus.shared.isConnected
            && !NetworkStatus.shared.isExpensive
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static func prefetchArtwork(client: PlexAPIClient, server: PlexServer, sectionId: String) async {
        guard canPrefetch else { return }
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)

        let albums = await LibraryStore.shared.items(kind: LibraryStore.Kind.album, scope: scope)
            .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        let artists = await LibraryStore.shared.items(kind: LibraryStore.Kind.artist, scope: scope)
        let playlists = await LibraryStore.shared.playlists(serverId: server.machineIdentifier)

        var paths: [String] = albums.compactMap(\.thumb)
        paths += artists.compactMap(\.thumb)
        paths += playlists.compactMap { $0.composite ?? $0.thumb }

        let urls = paths.compactMap {
            client.artworkURL(server: server, path: $0, width: artworkPixelSize, height: artworkPixelSize)
        }
        for chunk in stride(from: 0, to: urls.count, by: 200) {
            guard !Task.isCancelled, canPrefetch else { return }
            await ImageCache.shared.storeToDisk(urls: Array(urls[chunk..<min(chunk + 200, urls.count)]), pixelSize: artworkPixelSize)
        }
    }
}
