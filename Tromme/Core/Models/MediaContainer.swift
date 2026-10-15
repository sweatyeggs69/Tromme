import Foundation

struct MediaContainer<T: Decodable & Sendable>: Decodable, Sendable {
    let size: Int?
    let totalSize: Int?
    let offset: Int?
    let identifier: String?
    let title1: String?
    let title2: String?
    let metadata: [T]?
    let image: [PlexImageResource]?
    let directory: [LibrarySection]?
    let hub: [Hub]?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset, identifier, title1, title2
        case metadata = "Metadata"
        case image = "Image"
        case directory = "Directory"
        case hub = "Hub"
    }
}
