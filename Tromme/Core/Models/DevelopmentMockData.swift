#if DEBUG
import Foundation

enum DevelopmentMockData {
    static let recentTracks: [PlexMetadata] = (1...10).map { index in
        PlexMetadata(
            ratingKey: "preview-track-\(index)",
            key: nil,
            type: "track",
            title: "Preview Track \(index)",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            year: nil,
            index: index,
            parentIndex: 1,
            duration: 180000,
            addedAt: nil,
            updatedAt: nil,
            viewCount: 1,
            lastViewedAt: 1_700_000_000 - index,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "Preview Album",
            grandparentTitle: "Preview Artist",
            parentRatingKey: "album-preview",
            grandparentRatingKey: "artist-preview",
            leafCount: nil,
            viewedLeafCount: nil,
            media: [
                PlexMedia(
                    id: index,
                    duration: 180000,
                    bitrate: 320,
                    audioChannels: 2,
                    audioCodec: "flac",
                    container: "flac",
                    part: [
                        PlexPart(
                            id: index,
                            key: "/library/parts/\(index)",
                            duration: 180000,
                            file: nil,
                            size: nil,
                            container: "flac",
                            stream: [
                                PlexStream(
                                    id: index,
                                    streamType: 2,
                                    codec: "flac",
                                    channels: 2,
                                    bitrate: 320,
                                    bitDepth: 24,
                                    samplingRate: 96000
                                )
                            ]
                        )
                    ]
                )
            ],
            genre: nil,
            country: nil
        )
    }

    static let recentAlbums: [PlexMetadata] = (1...10).map { index in
        PlexMetadata(
            ratingKey: "preview-album-\(index)",
            key: nil,
            type: "album",
            title: "Preview Album \(index)",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            year: 2024,
            index: nil,
            parentIndex: nil,
            duration: nil,
            addedAt: 1_700_000_000 - index,
            updatedAt: nil,
            viewCount: nil,
            lastViewedAt: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "Preview Artist",
            grandparentTitle: nil,
            parentRatingKey: nil,
            grandparentRatingKey: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            media: nil,
            genre: nil,
            country: nil
        )
    }

    static let allAlbums: [PlexMetadata] = (1...12).map { index in
        PlexMetadata(
            ratingKey: "all-albums-preview-\(index)",
            key: nil,
            type: "album",
            title: "Preview Album \(index)",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            year: 2024,
            index: nil,
            parentIndex: nil,
            duration: nil,
            addedAt: 1_700_000_000 - index,
            updatedAt: nil,
            viewCount: nil,
            lastViewedAt: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "Preview Artist",
            grandparentTitle: nil,
            parentRatingKey: nil,
            grandparentRatingKey: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            media: nil,
            genre: nil,
            country: nil
        )
    }
}
#endif
