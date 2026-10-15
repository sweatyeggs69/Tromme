import Foundation

struct PlexResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let mediaContainer: MediaContainer<T>

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}
