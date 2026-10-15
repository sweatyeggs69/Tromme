import Foundation

struct PlexArtworkResourceResponse: Decodable, Sendable {
    let mediaContainer: PlexArtworkResourceContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}
