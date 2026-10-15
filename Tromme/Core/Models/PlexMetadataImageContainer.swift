import Foundation

struct PlexMetadataImageContainer: Decodable, Sendable {
    let metadata: [PlexMetadataImageItem]?

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
    }
}
