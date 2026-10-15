import SwiftUI
import Observation

/// Loading for `ArtistDetailView`; the view only renders this state.
@Observable @MainActor
final class ArtistDetailViewModel {
    let artist: PlexMetadata
    let isPreviewMode: Bool

    private(set) var resolvedArtist: PlexMetadata?
    private(set) var artistTracks: [PlexMetadata]
    private(set) var allTracks: [PlexMetadata]
    private(set) var topTracks: [PlexMetadata]
    private(set) var artistAlbums: [PlexMetadata]
    private(set) var appearsOnAlbums: [PlexMetadata]
    private(set) var similarArtists: [PlexMetadata]
    private(set) var contentReady = false

    init(artist: PlexMetadata, previewData: ArtistDetailView.PreviewData? = nil) {
        self.artist = artist
        isPreviewMode = previewData != nil
        resolvedArtist = previewData?.resolvedArtist
        artistTracks = previewData?.artistTracks ?? []
        allTracks = previewData?.allTracks ?? previewData?.artistTracks ?? []
        topTracks = previewData?.topTracks ?? []
        artistAlbums = previewData?.artistAlbums ?? []
        appearsOnAlbums = previewData?.appearsOnAlbums ?? []
        similarArtists = previewData?.similarArtists ?? []
    }

    /// Everything the loaders need from the environment.
    struct Context {
        let server: PlexServer?
        let sectionId: String?
        let client: PlexAPIClient
        let isConnected: Bool
        let downloadManager: DownloadManager
    }

    var displayArtist: PlexMetadata {
        resolvedArtist ?? artist
    }

    func load(_ context: Context) async {
        guard !isPreviewMode else { return }

        if !context.isConnected {
            // Prefer disk-cached data so non-downloaded albums and all tracks appear.
            let didLoadFromCache = await loadFromDiskCache(context)
            if !didLoadFromCache { loadOfflineContent(context) }
            return
        }

        guard let server = context.server,
              let sectionId = context.sectionId else { return }
        let client = context.client
        let artist = artist

        // Load all data in parallel instead of sequentially
        async let metadataReq = client.cachedMetadata(server: server, ratingKey: artist.ratingKey)
        async let releasesReq = client.cachedArtistReleases(server: server, sectionId: sectionId, artist: artist)
        async let artistTracksReq = client.cachedArtistTracks(server: server, sectionId: sectionId, artist: artist)
        async let allTracksReq = client.allArtistTracks(server: server, sectionId: sectionId, artist: artist)
        async let appearsOnReq = client.appearsOnAlbums(server: server, sectionId: sectionId, artistRatingKey: artist.ratingKey, artistTitle: artist.title)
        async let similarArtistsReq = client.similarArtists(server: server, sectionId: sectionId, seedArtistKey: artist.ratingKey)

        let fetchedMetadata = try? await metadataReq
        let fetchedArtistTracks = (try? await artistTracksReq) ?? []
        let fetchedAllTracks = (try? await allTracksReq) ?? fetchedArtistTracks
        let fetchedAlbums = (try? await releasesReq) ?? []
        let fetchedAppearsOn = (try? await appearsOnReq) ?? []
        let fetchedSimilar = (try? await similarArtistsReq) ?? []

        withAnimation(.easeIn(duration: 0.25)) {
            resolvedArtist = fetchedMetadata
            artistTracks = fetchedArtistTracks
            allTracks = fetchedAllTracks
            artistAlbums = fetchedAlbums
            appearsOnAlbums = fetchedAppearsOn
            similarArtists = fetchedSimilar
            topTracks = Self.topTracks(from: fetchedAllTracks)
            contentReady = true
        }
    }

    private static func topTracks(from tracks: [PlexMetadata]) -> [PlexMetadata] {
        Array(tracks.sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }.prefix(10))
    }

    /// Reads artist data from disk cache without any network calls.
    /// Returns true if enough data was found to populate the view.
    private func loadFromDiskCache(_ context: Context) async -> Bool {
        guard let server = context.server,
              let sectionId = context.sectionId else { return false }
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
        let artistKey = artist.ratingKey

        async let storedMetadata = LibraryStore.shared.anyMetadata(ratingKey: artistKey, serverId: server.machineIdentifier)
        async let storedAlbums = LibraryStore.shared.children(of: artistKey, scope: scope)
        async let storedTracks = LibraryStore.shared.tracks(byArtist: artistKey, scope: scope)

        let (metadata, albums, tracks) = await (storedMetadata, storedAlbums, storedTracks)

        guard !tracks.isEmpty else { return false }

        withAnimation(.easeIn(duration: 0.25)) {
            resolvedArtist = metadata
            artistTracks = tracks
            allTracks = tracks
            artistAlbums = albums
            topTracks = Self.topTracks(from: tracks)
            appearsOnAlbums = []
            similarArtists = []
            contentReady = true
        }
        return true
    }

    private func loadOfflineContent(_ context: Context) {
        let artistKey = artist.ratingKey
        let artistTitle = artist.title
        let records = context.downloadManager.downloadedTracksSorted.filter { record in
            record.artistRatingKey == artistKey || record.artistName == artistTitle
        }
        var seenAlbums = Set<String>()
        artistAlbums = records.compactMap { record -> PlexMetadata? in
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
        artistTracks = records.map { $0.asPlexMetadata() }
        allTracks = artistTracks
        topTracks = artistTracks
        appearsOnAlbums = []
        contentReady = true
    }
}
