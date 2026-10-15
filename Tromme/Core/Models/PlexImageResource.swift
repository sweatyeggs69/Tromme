import Foundation

struct PlexImageResource: Codable, Sendable, Hashable, Identifiable {
    let key: String?
    let provider: String?
    let type: String?
    let url: String?
    let thumb: String?
    let selected: Bool?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case key, provider, type, url, thumb, selected, width, height
    }

    var id: String {
        if let key, !key.isEmpty { return key }
        if let url, !url.isEmpty { return url }
        return "\(provider ?? "unknown")-\(type ?? "image")-\(width ?? 0)x\(height ?? 0)"
    }

    var resolutionText: String {
        guard let width, let height else { return "Resolution unavailable" }
        return "\(width) × \(height)"
    }

    init(
        key: String?,
        provider: String?,
        type: String?,
        url: String?,
        thumb: String?,
        selected: Bool?,
        width: Int?,
        height: Int?
    ) {
        self.key = key
        self.provider = provider
        self.type = type
        self.url = url
        self.thumb = thumb
        self.selected = selected
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try? container.decodeIfPresent(String.self, forKey: .key)
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        thumb = try? container.decodeIfPresent(String.self, forKey: .thumb)
        selected = Self.decodeFlexibleBool(from: container, forKey: .selected)
        width = Self.decodeFlexibleInt(from: container, forKey: .width)
        height = Self.decodeFlexibleInt(from: container, forKey: .height)
    }

    private static func decodeFlexibleInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private static func decodeFlexibleBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
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
