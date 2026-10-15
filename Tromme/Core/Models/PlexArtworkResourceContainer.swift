import Foundation

struct PlexArtworkResourceContainer: Decodable, Sendable {
    let image: [PlexImageResource]?
    let metadata: [PlexArtworkResourceMetadata]?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case metadata = "Metadata"
    }
}
