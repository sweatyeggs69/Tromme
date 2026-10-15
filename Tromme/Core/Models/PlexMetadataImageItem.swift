import Foundation

struct PlexMetadataImageItem: Decodable, Sendable {
    let image: [PlexImageResource]?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
    }
}
