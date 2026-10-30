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
    let sourceUpdatedAt: Int?

    var id: String { ratingKey }

    var fileExtension: String {
        URL(fileURLWithPath: relativeFilePath).pathExtension.lowercased()
    }

    func codecLabel(source: PlexMedia?) -> String {
        let aacContainers = ["m4a", "mp4"]
        if aacContainers.contains(fileExtension),
           let container = source?.container?.lowercased(),
           !aacContainers.contains(container) {
            return "AAC"
        }
        return fileExtension.uppercased()
    }

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
