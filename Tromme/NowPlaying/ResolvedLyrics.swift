import Foundation
import CryptoKit
import Observation

/// What the fallback chain settled on: a timed LRC (word- or line-synced) or plain text.
/// Also the shape of an LRCLIB search result, whose `duration` (seconds) is used for matching.
struct ResolvedLyrics: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?

    var hasSynced: Bool { syncedLyrics?.isEmpty == false }

    /// Identifies the lyrics text itself (synced if present, else plain), so a
    /// result the user blocked is recognized whichever source returns it.
    var fingerprint: String? {
        guard let text = hasSynced ? syncedLyrics : plainLyrics, !text.isEmpty else { return nil }
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
