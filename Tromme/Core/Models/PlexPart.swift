import Foundation

struct PlexPart: Codable, Sendable, Hashable {
    let id: Int?
    let key: String?
    let duration: Int?
    let file: String?
    let size: Int?
    let container: String?
    let stream: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case id, key, duration, file, size, container
        case stream = "Stream"
    }

    init(
        id: Int? = nil,
        key: String? = nil,
        duration: Int? = nil,
        file: String? = nil,
        size: Int? = nil,
        container: String? = nil,
        stream: [PlexStream]? = nil
    ) {
        self.id = id
        self.key = key
        self.duration = duration
        self.file = file
        self.size = size
        self.container = container
        self.stream = stream
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func decodeFlexibleInt(_ key: CodingKeys) -> Int? {
            if let value = try? c.decode(Int.self, forKey: key) { return value }
            if let value = try? c.decode(String.self, forKey: key), let intValue = Int(value) { return intValue }
            return nil
        }

        id = decodeFlexibleInt(.id)
        key = try? c.decodeIfPresent(String.self, forKey: .key)
        duration = decodeFlexibleInt(.duration)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        size = decodeFlexibleInt(.size)
        container = try? c.decodeIfPresent(String.self, forKey: .container)
        stream = try? c.decodeIfPresent([PlexStream].self, forKey: .stream)
    }
}
