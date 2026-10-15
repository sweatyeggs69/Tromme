import Foundation

struct PlexMetadataImageResponse: Decodable, Sendable {
    let mediaContainer: PlexMetadataImageContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}
