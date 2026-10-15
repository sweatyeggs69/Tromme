import Foundation
import Observation

struct DownloadedTrackRecord: Codable, Identifiable, Sendable {
    let ratingKey: String
    let title: String
    let artistName: String
    let albumName: String
    let albumRatingKey: String?
    let artistRatingKey: String?
    let thumbPath: String?
    let relativeFilePath: String
    let downloadedAt: Date
    let fileSize: Int64
    let durationMs: Int?
    /// The Plex `updatedAt` Unix timestamp at the time of download. Used to detect
    /// when the source file is replaced so the download can be refreshed automatically.
    let sourceUpdatedAt: Int?

    var id: String { ratingKey }

    func asPlexMetadata() -> PlexMetadata {
        PlexMetadata(
            ratingKey: ratingKey,
            title: title,
            grandparentTitle: artistName,
            parentTitle: albumName,
            parentRatingKey: albumRatingKey,
            thumbPath: thumbPath,
            durationMs: durationMs
        )
    }
}
