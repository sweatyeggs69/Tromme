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

    var fileExtension: String {
        URL(fileURLWithPath: relativeFilePath).pathExtension.lowercased()
    }

    /// Display codec for the stored file. An m4a made from a non-m4a source is a Space Saver AAC transcode.
    func codecLabel(source: PlexMedia?) -> String {
        let aacContainers = ["m4a", "mp4"]
        if aacContainers.contains(fileExtension),
           let container = source?.container?.lowercased(),
           !aacContainers.contains(container) {
            return "AAC"
        }
        return fileExtension.uppercased()
    }

    /// Average bitrate of the stored file, which differs from the Plex source for Space Saver downloads.
    var averageBitrateKbps: Int? {
        guard let durationMs, durationMs > 0 else { return nil }
        return Int(Double(fileSize) * 8 / Double(durationMs))
    }

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
