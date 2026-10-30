import Foundation

struct PlexTagListResponse: Decodable, Sendable {
    let mediaContainer: Container

    struct Container: Decodable, Sendable {
        let entries: [Entry]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let directory = try c.decodeIfPresent([Entry].self, forKey: .directory)
            let filter = try c.decodeIfPresent([Entry].self, forKey: .filter)
            entries = directory ?? filter ?? []
        }

        enum CodingKeys: String, CodingKey {
            case directory = "Directory"
            case filter = "Filter"
        }
    }

    struct Entry: Decodable, Sendable {
        let filter: String?
        let key: String?
        let tag: String?
        let title: String?
    }

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}
