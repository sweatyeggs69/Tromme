import Foundation

struct PlexStream: Codable, Sendable, Hashable {
    let id: Int?
    let streamType: Int?
    let codec: String?
    let channels: Int?
    let bitrate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let gain: Double?
    let albumGain: Double?

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, channels, bitrate, bitDepth, samplingRate, gain, albumGain
    }

    init(
        id: Int? = nil,
        streamType: Int? = nil,
        codec: String? = nil,
        channels: Int? = nil,
        bitrate: Int? = nil,
        bitDepth: Int? = nil,
        samplingRate: Int? = nil,
        gain: Double? = nil,
        albumGain: Double? = nil
    ) {
        self.id = id
        self.streamType = streamType
        self.codec = codec
        self.channels = channels
        self.bitrate = bitrate
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.gain = gain
        self.albumGain = albumGain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func decodeFlexibleInt(_ key: CodingKeys) -> Int? {
            if let value = try? c.decode(Int.self, forKey: key) { return value }
            if let value = try? c.decode(String.self, forKey: key), let intValue = Int(value) { return intValue }
            return nil
        }

        func decodeFlexibleDouble(_ key: CodingKeys) -> Double? {
            if let value = try? c.decode(Double.self, forKey: key) { return value }
            if let value = try? c.decode(String.self, forKey: key), let doubleValue = Double(value) { return doubleValue }
            return nil
        }

        id = decodeFlexibleInt(.id)
        streamType = decodeFlexibleInt(.streamType)
        codec = try? c.decodeIfPresent(String.self, forKey: .codec)
        channels = decodeFlexibleInt(.channels)
        bitrate = decodeFlexibleInt(.bitrate)
        bitDepth = decodeFlexibleInt(.bitDepth)
        samplingRate = decodeFlexibleInt(.samplingRate)
        gain = decodeFlexibleDouble(.gain)
        albumGain = decodeFlexibleDouble(.albumGain)
    }
}
