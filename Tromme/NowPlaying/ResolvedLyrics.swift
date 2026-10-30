import Foundation
import CryptoKit
import Observation

struct ResolvedLyrics: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?
    var source: LyricsSource?

    var hasSynced: Bool { syncedLyrics?.isEmpty == false }

    private var text: String? {
        guard let text = hasSynced ? syncedLyrics : plainLyrics, !text.isEmpty else { return nil }
        return text
    }

    var fingerprint: String? {
        text.map { Self.hash(Self.normalized($0)) }
    }

    var textFingerprint: String? {
        text.map { Self.hash(Self.normalized(Self.strippingTimestamps($0))) }
    }

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
