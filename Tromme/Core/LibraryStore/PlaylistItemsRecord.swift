import Foundation
import SwiftData

@Model
final class PlaylistItemsRecord {
    @Attribute(.unique) var id: String
    var serverId: String
    var ratingKey: String
    var payload: Data
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
