import Foundation
import SwiftData

/// The ordered tracks of one playlist, stored as a single JSON array so order and each
/// entry's `playlistItemID` (needed for reordering) are kept exactly as the server sent them.
@Model
final class PlaylistItemsRecord {
    /// Same id as the matching `PlaylistRecord`.
    @Attribute(.unique) var id: String
    var serverId: String
    var ratingKey: String
    /// JSON-encoded `[PlexMetadata]`.
    var payload: Data
    /// The playlist's `updatedAt` / `leafCount` when these items were fetched — compared
    /// against the latest listing to decide whether a re-fetch is needed.
    var playlistUpdatedAt: Int?
    var playlistLeafCount: Int?

    init(id: String, serverId: String, ratingKey: String, payload: Data, playlistUpdatedAt: Int?, playlistLeafCount: Int?) {
        self.id = id
        self.serverId = serverId
        self.ratingKey = ratingKey
        self.payload = payload
        self.playlistUpdatedAt = playlistUpdatedAt
        self.playlistLeafCount = playlistLeafCount
    }
}
