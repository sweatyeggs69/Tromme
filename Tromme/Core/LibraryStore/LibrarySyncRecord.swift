import Foundation
import SwiftData

@Model
final class LibrarySyncRecord {
    @Attribute(.unique) var scope: String
    var metaReady: Bool = false
    var tracksReady: Bool = false
    var serverUpdatedAt: Int = 0
    var lastSyncedAt: Date = Date.distantPast

    init(scope: String) {
        self.scope = scope
    }
}
