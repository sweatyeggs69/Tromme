import Foundation
import SwiftData

/// One Plex playlist (the listing entry, not its tracks).
@Model
final class PlaylistRecord {
    /// "\(serverId)|\(ratingKey)"
    @Attribute(.unique) var id: String
    var serverId: String
    var ratingKey: String
    /// Server order, preserved so the list renders as Plex returns it.
    var position: Int
    /// JSON-encoded `PlexPlaylist`.
    var payload: Data
    var updatedAt: Int?
    var leafCount: Int?

    init(id: String, serverId: String, ratingKey: String, position: Int, payload: Data, updatedAt: Int?, leafCount: Int?) {
        self.id = id
        self.serverId = serverId
        self.ratingKey = ratingKey
        self.position = position
        self.payload = payload
        self.updatedAt = updatedAt
        self.leafCount = leafCount
    }
}
