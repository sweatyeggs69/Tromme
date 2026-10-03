import Foundation
import SwiftData

/// Per-server state that isn't part of a library section: the section list (for the
/// library pickers) and whether playlists have ever been mirrored.
@Model
final class ServerRecord {
    @Attribute(.unique) var serverId: String
    /// JSON-encoded `[LibrarySection]`.
    var sectionsPayload: Data?
    var playlistsSyncedAt: Date?

    init(serverId: String) {
        self.serverId = serverId
    }
}
