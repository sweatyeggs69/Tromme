#if DEBUG
import Foundation

enum DevelopmentMockData {
    static let previewArtist: PlexMetadata = makeArtist(
        ratingKey: "artist-preview-1",
        title: "Radiohead",
        summary: "English alternative rock band formed in Abingdon, Oxfordshire.",
        year: 1985,
        albumCount: 12
    )

    static let artistTopTracks: [PlexMetadata] = (1...12).map { index in
        makeTrack(
            ratingKey: "artist-top-track-\(index)",
            title: "Top Song \(index)",
            albumTitle: "Album \(Int((Double(index) / 3.0).rounded(.up)))",
            albumRatingKey: "artist-album-\(Int((Double(index) / 3.0).rounded(.up)))",
            artistTitle: previewArtist.title,
            artistRatingKey: previewArtist.ratingKey,
            trackIndex: index,
            durationMs: 170_000 + (index * 9_000),
            viewCount: max(1, 50 - index),
            lastViewedAt: 1_700_000_000 - index
        )
    }

    static let artistAlbums: [PlexMetadata] = (1...14).map { index in
        makeAlbum(
            ratingKey: "artist-album-\(index)",
            title: "Album \(index)",
            artistTitle: previewArtist.title,
            year: 1994 + index,
            addedAt: 1_700_000_000 - index
        )
    }

    static let artistAllTracks: [PlexMetadata] = (1...32).map { index in
        makeTrack(
            ratingKey: "artist-all-track-\(index)",
            title: "Track \(index)",
            albumTitle: "Album \(Int((Double(index) / 3.0).rounded(.up)))",
            albumRatingKey: "artist-album-\(Int((Double(index) / 3.0).rounded(.up)))",
            artistTitle: previewArtist.title,
            artistRatingKey: previewArtist.ratingKey,
            trackIndex: (index % 12) + 1,
            durationMs: 150_000 + (index * 6_000),
            viewCount: max(1, 120 - index),
            lastViewedAt: 1_700_000_000 - index
        )
    }

    static let recentTracks: [PlexMetadata] = Array(artistAllTracks.prefix(10))
    static let recentAlbums: [PlexMetadata] = Array(artistAlbums.prefix(10))

    static let allAlbums: [PlexMetadata] = (1...24).map { index in
        makeAlbum(
            ratingKey: "all-albums-preview-\(index)",
            title: "Preview Album \(index)",
            artistTitle: "Preview Artist \(Int((Double(index) / 3.0).rounded(.up)))",
            year: 2001 + (index % 20),
            addedAt: 1_700_000_000 - index
        )
    }

    static let allSongs: [PlexMetadata] = (1...50).map { index in
        makeTrack(
            ratingKey: "all-songs-preview-\(index)",
            title: "Preview Song \(index)",
            albumTitle: "Preview Album \(Int((Double(index) / 4.0).rounded(.up)))",
            albumRatingKey: "all-songs-album-\(Int((Double(index) / 4.0).rounded(.up)))",
            artistTitle: "Preview Artist \(Int((Double(index) / 7.0).rounded(.up)))",
            artistRatingKey: "all-songs-artist-\(Int((Double(index) / 7.0).rounded(.up)))",
            trackIndex: (index % 12) + 1,
            durationMs: 165_000 + (index * 2_000),
            viewCount: max(1, 70 - index),
            lastViewedAt: 1_700_000_000 - index
        )
    }

    static let allArtists: [PlexMetadata] = [
        previewArtist,
        makeArtist(ratingKey: "artist-preview-2", title: "Nujabes", summary: "Japanese producer and DJ.", year: 1995, albumCount: 4),
        makeArtist(ratingKey: "artist-preview-3", title: "Massive Attack", summary: "British trip hop collective.", year: 1988, albumCount: 8),
        makeArtist(ratingKey: "artist-preview-4", title: "Portishead", summary: "English trip hop band from Bristol.", year: 1991, albumCount: 3),
        makeArtist(ratingKey: "artist-preview-5", title: "Mogwai", summary: "Scottish post-rock band.", year: 1995, albumCount: 11),
    ]

    static let previewPlaylist: PlexPlaylist = PlexPlaylist(
        ratingKey: "playlist-preview-1",
        key: "/playlists/playlist-preview-1",
        type: "playlist",
        title: "Late Night Mix",
        summary: "Headphones recommended",
        smart: false,
        playlistType: "audio",
        composite: nil,
        duration: 3_600_000,
        leafCount: 18,
        addedAt: 1_700_000_000,
        updatedAt: 1_700_000_100
    )

    static let previewPlaylistTracks: [PlexMetadata] = Array(allSongs.prefix(18))

    private static func makeArtist(
        ratingKey: String,
        title: String,
        summary: String,
        year: Int,
        albumCount: Int
    ) -> PlexMetadata {
        PlexMetadata(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            type: "artist",
            subtype: nil,
            title: title,
            titleSort: title,
            originalTitle: nil,
            summary: summary,
            year: year,
            index: nil,
            parentIndex: nil,
            duration: nil,
            addedAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            viewCount: nil,
            lastViewedAt: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: nil,
            grandparentTitle: nil,
            parentRatingKey: nil,
            grandparentRatingKey: nil,
            leafCount: albumCount,
            viewedLeafCount: nil,
            media: nil,
            genre: [PlexTag(tag: "Alternative")],
            style: [PlexTag(tag: "Art Rock")],
            country: [PlexTag(tag: "United Kingdom")],
            subformat: nil, originallyAvailableAt: nil
        )
    }

    private static func makeAlbum(
        ratingKey: String,
        title: String,
        artistTitle: String,
        year: Int,
        addedAt: Int
    ) -> PlexMetadata {
        PlexMetadata(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            type: "album",
            subtype: nil,
            title: title,
            titleSort: title,
            originalTitle: nil,
            summary: nil,
            year: year,
            index: nil,
            parentIndex: nil,
            duration: nil,
            addedAt: addedAt,
            updatedAt: addedAt + 100,
            viewCount: nil,
            lastViewedAt: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: artistTitle,
            grandparentTitle: nil,
            parentRatingKey: nil,
            grandparentRatingKey: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            media: nil,
            genre: [PlexTag(tag: "Alternative")],
            style: nil,
            country: nil,
            subformat: nil, originallyAvailableAt: nil
        )
    }

    private static func makeTrack(
        ratingKey: String,
        title: String,
        albumTitle: String,
        albumRatingKey: String,
        artistTitle: String,
        artistRatingKey: String,
        trackIndex: Int,
        durationMs: Int,
        viewCount: Int,
        lastViewedAt: Int
    ) -> PlexMetadata {
        PlexMetadata(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            type: "track",
            subtype: nil,
            title: title,
            titleSort: title,
            originalTitle: nil,
            summary: nil,
            year: nil,
            index: trackIndex,
            parentIndex: 1,
            duration: durationMs,
            addedAt: 1_700_000_000 - trackIndex,
            updatedAt: 1_700_000_100 - trackIndex,
            viewCount: viewCount,
            lastViewedAt: lastViewedAt,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: albumTitle,
            grandparentTitle: artistTitle,
            parentRatingKey: albumRatingKey,
            grandparentRatingKey: artistRatingKey,
            leafCount: nil,
            viewedLeafCount: nil,
            media: [
                PlexMedia(
                    id: trackIndex,
                    duration: durationMs,
                    bitrate: 320,
                    audioChannels: 2,
                    audioCodec: "flac",
                    container: "flac",
                    part: [
                        PlexPart(
                            id: trackIndex,
                            key: "/library/parts/\(trackIndex)",
                            duration: durationMs,
                            file: nil,
                            size: nil,
                            container: "flac",
                            stream: [
                                PlexStream(
                                    id: trackIndex,
                                    streamType: 2,
                                    codec: "flac",
                                    channels: 2,
                                    bitrate: 320,
                                    bitDepth: 24,
                                    samplingRate: 96_000
                                )
                            ]
                        )
                    ]
                )
            ],
            genre: [PlexTag(tag: "Alternative")],
            style: nil,
            country: nil,
            subformat: nil, originallyAvailableAt: nil
        )
    }
}
#endif
