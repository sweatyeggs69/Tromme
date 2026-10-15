import Foundation

/// A server-curated home row from `/hubs/sections/{sectionId}` (e.g. "More by X", "Top Albums from 2026").
struct PlexHub: Decodable, Sendable, Identifiable, Hashable {
    let hubIdentifier: String?
    let key: String?
    let title: String
    let type: String?
    let items: [PlexMetadata]

    var id: String { hubIdentifier ?? key ?? title }

    enum CodingKeys: String, CodingKey {
        case hubIdentifier, key, title, type
        case items = "Metadata"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hubIdentifier = try container.decodeIfPresent(String.self, forKey: .hubIdentifier)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        // Decode leniently so one malformed entry doesn't drop the whole row.
        let lossy = try container.decodeIfPresent([LossyItem].self, forKey: .items) ?? []
        items = lossy.compactMap(\.value)
    }

    private struct LossyItem: Decodable {
        let value: PlexMetadata?
        init(from decoder: Decoder) throws {
            value = try? PlexMetadata(from: decoder)
        }
    }
}

struct PlexHubsResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        let hubs: [PlexHub]?
        enum CodingKeys: String, CodingKey { case hubs = "Hub" }
    }
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}
