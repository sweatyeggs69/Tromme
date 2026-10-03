import Foundation
import SwiftData

/// Sync bookkeeping for one server + library section.
@Model
final class LibrarySyncRecord {
    @Attribute(.unique) var scope: String
    /// Artists and albums have been fully mirrored at least once.
    var metaReady: Bool = false
    /// Tracks have been fully mirrored at least once.
    var tracksReady: Bool = false
    /// The section's `updatedAt` as of the last completed sync.
    var serverUpdatedAt: Int = 0
    var lastSyncedAt: Date = Date.distantPast

    init(scope: String) {
        self.scope = scope
    }
}
