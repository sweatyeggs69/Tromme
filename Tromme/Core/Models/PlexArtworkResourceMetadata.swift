import Foundation

struct PlexArtworkResourceMetadata: Decodable, Sendable {
    let key: String?
    let url: String?
    let thumb: String?
    let provider: String?
    let type: String?
    let selected: Bool?
    let width: Int?
    let height: Int?

    var asImageResource: PlexImageResource {
        PlexImageResource(
            key: key,
            provider: provider,
            type: type,
            url: url,
            thumb: thumb,
            selected: selected,
            width: width,
            height: height
        )
    }

    enum CodingKeys: String, CodingKey {
        case key, url, thumb, provider, type, selected, width, height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try? c.decodeIfPresent(String.self, forKey: .key)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        selected = Self.decodeFlexibleBool(from: c, forKey: .selected)
        width = Self.decodeFlexibleInt(from: c, forKey: .width)
        height = Self.decodeFlexibleInt(from: c, forKey: .height)
    }

    private static func decodeFlexibleInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func decodeFlexibleBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
