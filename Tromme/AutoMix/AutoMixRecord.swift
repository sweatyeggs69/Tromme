import Foundation

/// What Auto Mix decided for one pair of songs and what happened, kept for the issue report.
struct AutoMixRecord: Sendable {
    let outgoing: PlexMetadata
    let incoming: PlexMetadata
    var outcome: String
    var values: [String: String]
}
