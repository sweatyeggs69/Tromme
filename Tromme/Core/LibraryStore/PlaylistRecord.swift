import Foundation
import SwiftData

@Model
final class PlaylistRecord {
    @Attribute(.unique) var id: String
    var serverId: String
    var ratingKey: String
    var position: Int
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
