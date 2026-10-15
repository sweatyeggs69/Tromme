import Foundation

struct PlexMedia: Codable, Sendable, Hashable {
    let id: Int?
    let duration: Int?
    let bitrate: Int?
    let audioChannels: Int?
    let audioCodec: String?
    let container: String?
    let part: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, audioChannels, audioCodec, container
        case part = "Part"
    }

    init(
        id: Int? = nil,
        duration: Int? = nil,
        bitrate: Int? = nil,
        audioChannels: Int? = nil,
        audioCodec: String? = nil,
        container: String? = nil,
        part: [PlexPart]? = nil
    ) {
        self.id = id
        self.duration = duration
        self.bitrate = bitrate
        self.audioChannels = audioChannels
        self.audioCodec = audioCodec
        self.container = container
        self.part = part
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func decodeFlexibleInt(_ key: CodingKeys) -> Int? {
            if let value = try? c.decode(Int.self, forKey: key) { return value }
            if let value = try? c.decode(String.self, forKey: key), let intValue = Int(value) { return intValue }
            return nil
        }

        id = decodeFlexibleInt(.id)
        duration = decodeFlexibleInt(.duration)
        bitrate = decodeFlexibleInt(.bitrate)
        audioChannels = decodeFlexibleInt(.audioChannels)
        audioCodec = try? c.decodeIfPresent(String.self, forKey: .audioCodec)
        container = try? c.decodeIfPresent(String.self, forKey: .container)
        part = try? c.decodeIfPresent([PlexPart].self, forKey: .part)
    }
}
