import Foundation
import Observation

/// What the fallback chain settled on: a timed LRC (word- or line-synced) or plain text.
/// Also the shape of an LRCLIB search result, whose `duration` (seconds) is used for matching.
struct ResolvedLyrics: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?

    var hasSynced: Bool { syncedLyrics?.isEmpty == false }
}
