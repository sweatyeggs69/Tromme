import Foundation

/// Downloads everything the browsing UI renders so it never waits on the server: artwork
/// for the whole library at full resolution (written to the persistent image store), plus
/// the playlists' covers. Safe to re-run — files already stored at full size are skipped,
/// so an interrupted run just resumes next time.
enum LibraryPrefetcher {
    /// One stored size serves every surface (rows, grids, headers, Now Playing).
    /// Matches `ArtworkView.maxTranscodePx` (main-actor isolated, so not referenced here).
    private static let artworkPixelSize = 1000

    private static var canPrefetch: Bool {
        NetworkStatus.shared.isConnected
            && !NetworkStatus.shared.isExpensive
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Artwork for albums (newest first), artists, playlists, then any distinct track art.
    static func prefetchArtwork(client: PlexAPIClient, server: PlexServer, sectionId: String, includeTracks: Bool) async {
        guard canPrefetch else { return }
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)

        let albums = await LibraryStore.shared.items(kind: LibraryStore.Kind.album, scope: scope)
            .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        let artists = await LibraryStore.shared.items(kind: LibraryStore.Kind.artist, scope: scope)
        let playlists = await LibraryStore.shared.playlists(serverId: server.machineIdentifier)

        var paths: [String] = albums.compactMap(\.thumb)
        paths += artists.compactMap(\.thumb)
        paths += playlists.compactMap { $0.composite ?? $0.thumb }
        if includeTracks {
            paths += await LibraryStore.shared.trackThumbPaths(scope: scope)
        }

        let urls = paths.compactMap {
            client.artworkURL(server: server, path: $0, width: artworkPixelSize, height: artworkPixelSize)
        }
        // Chunked so a dropped connection / Low Power Mode flip stops the run promptly.
        for chunk in stride(from: 0, to: urls.count, by: 200) {
            guard !Task.isCancelled, canPrefetch else { return }
            await ImageCache.shared.storeToDisk(urls: Array(urls[chunk..<min(chunk + 200, urls.count)]), pixelSize: artworkPixelSize)
        }
    }
}
