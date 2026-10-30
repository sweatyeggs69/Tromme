import Foundation
import SwiftData

@Model
final class ServerRecord {
    @Attribute(.unique) var serverId: String
    var sectionsPayload: Data?
    var playlistsSyncedAt: Date?

    init(serverId: String) {
        self.serverId = serverId
    }
}
