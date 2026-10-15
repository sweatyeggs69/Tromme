import Foundation
import CryptoKit
import Observation

/// What the fallback chain settled on: a timed LRC (word- or line-synced) or plain text.
/// Also the shape of an LRCLIB search result, whose `duration` (seconds) is used for matching.
struct ResolvedLyrics: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?
    /// Absent in LRCLIB's JSON and in older cache entries.
    var source: LyricsSource?

    var hasSynced: Bool { syncedLyrics?.isEmpty == false }

    private var text: String? {
        guard let text = hasSynced ? syncedLyrics : plainLyrics, !text.isEmpty else { return nil }
        return text
    }

    /// Identifies these exact lyrics, timing included, so blocking one timed version
    /// still leaves other timings of the same words available.
    var fingerprint: String? {
        text.map { Self.hash(Self.normalized($0)) }
    }

    /// Identifies just the words, with timestamps dropped, so blocking a timed version
    /// also blocks the same words as plain text.
    var textFingerprint: String? {
        text.map { Self.hash(Self.normalized(Self.strippingTimestamps($0))) }
    }

    /// Trims each line and drops blank ones, so copies that differ only in
    /// whitespace or line endings count as the same lyrics.
    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func strippingTimestamps(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[[^\\]]*\\]|<[^>]*>", with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "\n")
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
