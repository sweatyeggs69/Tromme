import Foundation

struct AutoMixRecord: Sendable {
    let outgoing: PlexMetadata
    let incoming: PlexMetadata
    var outcome: String
    var values: [String: String]
}
