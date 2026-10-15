import Foundation
import Observation

/// Loading and actions for `AlbumDetailView`; the view only renders this state.
@Observable @MainActor
final class AlbumDetailViewModel {
    let album: PlexMetadata
    let isPreviewMode: Bool

    private(set) var albumDetails: PlexMetadata
    private(set) var tracks: [PlexMetadata]
    private(set) var firstTrackDetails: PlexMetadata?
    private(set) var isLoadingTracks: Bool
    private(set) var artistAlbums: [PlexMetadata]
    private(set) var recommendedAlbums: [PlexMetadata]
    private(set) var popularTrackTitles: Set<String> = []
    private(set) var isDeletingAlbum = false
    /// Square Apple Music animated artwork for the header, when the album has it.
    private(set) var animatedArtworkURL: URL?
    var albumDeleteErrorMessage: String?

    init(
        album: PlexMetadata,
        previewTracks: [PlexMetadata]? = nil,
        previewArtistAlbums: [PlexMetadata] = [],
        previewRecommendedAlbums: [PlexMetadata] = []
    ) {
        self.album = album
        albumDetails = album
        tracks = previewTracks ?? []
        artistAlbums = previewArtistAlbums
        recommendedAlbums = previewRecommendedAlbums
        isLoadingTracks = previewTracks == nil
        isPreviewMode = previewTracks != nil
    }

    /// Everything the loaders need from the environment.
    struct Context {
        let server: PlexServer?
        let sectionId: String?
        let client: PlexAPIClient
        let isConnected: Bool
        let downloadManager: DownloadManager
        let showPopularTracks: Bool
    }

    var artistNavigationTarget: PlexMetadata? {
        let artistTitle = albumDetails.parentTitle ?? album.parentTitle
        let artistRatingKey = albumDetails.parentRatingKey ?? album.parentRatingKey
        guard let artistTitle, !artistTitle.isEmpty,
              let artistRatingKey, !artistRatingKey.isEmpty else { return nil }

        return PlexMetadata(
            ratingKey: artistRatingKey,
            title: artistTitle,
            type: "artist",
            thumb: albumDetails.parentThumb ?? album.parentThumb
        )
    }

    func load(_ context: Context) async {
        guard !isPreviewMode else { return }
        // .task restarts when popping back to the view; showing the spinner again would
        // collapse the track list and jump the scroll position.
        if tracks.isEmpty { isLoadingTracks = true }
        async let detailsTask: Void = loadAlbumDetails(context)
        async let tracksTask: Void = loadTracks(context)
        _ = await (detailsTask, tracksTask)
        guard !Task.isCancelled else { return }
        async let artistAlbumsTask: Void = loadArtistAlbums(context)
        async let recommendationsTask: Void = loadRecommendedAlbums(context)
        async let lastFMTask: Void = loadLastFMPopularity(context)
        _ = await (artistAlbumsTask, recommendationsTask, lastFMTask)
    }

    func loadAnimatedArtwork() async {
        guard !isPreviewMode, AnimatedArtworkEntitlement.isEnabled,
              let artist = albumDetails.parentTitle ?? album.parentTitle, !artist.isEmpty else {
            animatedArtworkURL = nil
            return
        }
        let artwork = await AnimatedArtworkService.artwork(artist: artist, album: album.title)
        guard !Task.isCancelled else { return }
        animatedArtworkURL = artwork?.square
    }

    func loadAlbumDetails(_ context: Context) async {
        guard let server = context.server else { return }
        do {
            albumDetails = try await context.client.cachedAlbumMetadata(server: server, ratingKey: album.ratingKey) ?? album
        } catch {
            albumDetails = album
        }
    }

    private func loadRecommendedAlbums(_ context: Context) async {
        guard let server = context.server,
              let sectionId = context.sectionId,
              let artistKey = albumDetails.parentRatingKey ?? album.parentRatingKey else { return }
        recommendedAlbums = (try? await context.client.albumsFromSimilarArtists(
            server: server, sectionId: sectionId, artistRatingKey: artistKey
        )) ?? []
    }

    private func loadTracks(_ context: Context) async {
        guard context.isConnected else {
            let albumKey = album.ratingKey
            let albumTitle = album.title
            let downloaded = context.downloadManager.downloadedTracksSorted.filter { record in
                record.albumRatingKey == albumKey || record.albumName == albumTitle
            }
            tracks = downloaded.map { $0.asPlexMetadata() }
            isLoadingTracks = false
            return
        }
        guard let server = context.server else {
            isLoadingTracks = false
            return
        }

        do {
            tracks = try await context.client.cachedChildren(server: server, ratingKey: album.ratingKey, updatedAt: album.updatedAt)
            if let firstTrack = tracks.first {
                firstTrackDetails = try await context.client.cachedMetadata(server: server, ratingKey: firstTrack.ratingKey)
            } else {
                firstTrackDetails = nil
            }
        } catch {
            if tracks.isEmpty {
                tracks = []
                firstTrackDetails = nil
            }
        }
        isLoadingTracks = false
    }

    private func loadArtistAlbums(_ context: Context) async {
        guard let artist = artistNavigationTarget else { return }

        guard context.isConnected else {
            var seenAlbums = Set<String>()
            artistAlbums = context.downloadManager.downloadedTracksSorted
                .filter { $0.artistRatingKey == artist.ratingKey || $0.artistName == artist.title }
                .compactMap { record -> PlexMetadata? in
                    let key = record.albumRatingKey ?? record.albumName
                    guard seenAlbums.insert(key).inserted else { return nil }
                    return PlexMetadata(
                        ratingKey: record.albumRatingKey ?? "offline:\(record.albumName)",
                        title: record.albumName,
                        type: "album",
                        parentTitle: record.artistName,
                        thumb: record.thumbPath
                    )
                }
            return
        }

        guard let server = context.server,
              let sectionId = context.sectionId else { return }
        do {
            artistAlbums = try await context.client.cachedArtistReleases(server: server, sectionId: sectionId, artist: artist)
        } catch {
            artistAlbums = []
        }
    }

    private func loadLastFMPopularity(_ context: Context) async {
        guard context.isConnected, context.showPopularTracks else { return }
        guard let artistName = albumDetails.parentTitle ?? album.parentTitle,
              !artistName.isEmpty, !tracks.isEmpty else { return }
        popularTrackTitles = await LastFMService.fetchPopularTracks(
            artist: artistName,
            albumTrackTitles: tracks.map(\.title)
        )
    }

    func removeTrack(_ track: PlexMetadata) {
        tracks.removeAll { $0.ratingKey == track.ratingKey }
    }

    /// Deletes the album on the server and locally. Returns true when the view should dismiss.
    func deleteAlbum(_ context: Context) async -> Bool {
        guard !isPreviewMode, let server = context.server, !isDeletingAlbum else { return false }

        isDeletingAlbum = true
        defer { isDeletingAlbum = false }

        do {
            try await context.client.deleteLibraryItem(server: server, ratingKey: album.ratingKey)
            for track in tracks { context.downloadManager.deleteDownload(ratingKey: track.ratingKey) }
            await LibraryStore.shared.remove(ratingKey: album.ratingKey, serverId: server.machineIdentifier)
            for track in tracks {
                await LibraryStore.shared.remove(ratingKey: track.ratingKey, serverId: server.machineIdentifier)
            }
            if let sectionId = context.sectionId {
                let client = context.client
                Task { await client.smartRefresh(server: server, sectionId: sectionId) }
            }
            return true
        } catch {
            albumDeleteErrorMessage = error.localizedDescription
            return false
        }
    }
}
