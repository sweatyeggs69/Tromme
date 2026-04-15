import Foundation

// MARK: - API Response Wrapper

struct PlexResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let mediaContainer: MediaContainer<T>

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

struct MediaContainer<T: Decodable & Sendable>: Decodable, Sendable {
    let size: Int?
    let totalSize: Int?
    let offset: Int?
    let identifier: String?
    let title1: String?
    let title2: String?
    let metadata: [T]?
    let directory: [LibrarySection]?
    let hub: [Hub]?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset, identifier, title1, title2
        case metadata = "Metadata"
        case directory = "Directory"
        case hub = "Hub"
    }
}

// MARK: - Library Section

struct LibrarySection: Codable, Sendable, Identifiable, Hashable {
    let key: String
    let type: String
    let title: String
    let agent: String?
    let scanner: String?
    let language: String?
    let uuid: String?
    let updatedAt: Int?
    let scannedAt: Int?
    let thumb: String?
    let art: String?

    var id: String { key }
    var isMusicLibrary: Bool { type == "artist" }
}

extension LibrarySection {
    enum CodingKeys: String, CodingKey {
        case key, type, title, agent, scanner, language, uuid
        case updatedAt, scannedAt, thumb, art
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // key and type can come as String or Int from Plex
        if let str = try? container.decode(String.self, forKey: .key) {
            key = str
        } else if let num = try? container.decode(Int.self, forKey: .key) {
            key = String(num)
        } else {
            key = ""
        }
        if let str = try? container.decode(String.self, forKey: .type) {
            type = str
        } else if let num = try? container.decode(Int.self, forKey: .type) {
            // Map Plex type numbers: 8 = artist (music library)
            switch num {
            case 1: type = "movie"
            case 2: type = "show"
            case 8: type = "artist"
            case 13: type = "photo"
            default: type = String(num)
            }
        } else {
            type = ""
        }
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        agent = try? container.decodeIfPresent(String.self, forKey: .agent)
        scanner = try? container.decodeIfPresent(String.self, forKey: .scanner)
        language = try? container.decodeIfPresent(String.self, forKey: .language)
        uuid = try? container.decodeIfPresent(String.self, forKey: .uuid)
        updatedAt = try? container.decodeIfPresent(Int.self, forKey: .updatedAt)
        scannedAt = try? container.decodeIfPresent(Int.self, forKey: .scannedAt)
        thumb = try? container.decodeIfPresent(String.self, forKey: .thumb)
        art = try? container.decodeIfPresent(String.self, forKey: .art)
    }
}

// MARK: - Plex Metadata (Artist / Album / Track)

struct PlexMetadata: Codable, Sendable, Identifiable, Hashable {
    let ratingKey: String
    let key: String?
    let type: String?
    let title: String
    let titleSort: String?
    let originalTitle: String?
    let summary: String?
    var studio: String? = nil
    let year: Int?
    let index: Int?
    let parentIndex: Int?
    let duration: Int?
    let addedAt: Int?
    let updatedAt: Int?
    let viewCount: Int?
    let lastViewedAt: Int?
    var userRating: Double? = nil
    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let media: [PlexMedia]?
    let genre: [PlexTag]?
    let country: [PlexTag]?

    var id: String { ratingKey }

    var durationFormatted: String {
        guard let duration else { return "" }
        let seconds = duration / 1000
        let min = seconds / 60
        let sec = seconds % 60
        return String(format: "%d:%02d", min, sec)
    }

    var artistName: String {
        grandparentTitle ?? parentTitle ?? ""
    }

    var albumName: String {
        parentTitle ?? ""
    }
}

extension PlexMetadata {
    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, titleSort, originalTitle, summary, studio
        case year, index, parentIndex, duration, addedAt, updatedAt
        case viewCount, lastViewedAt, userRating
        case thumb, art, parentThumb, grandparentThumb, grandparentArt
        case parentTitle, grandparentTitle, parentRatingKey, grandparentRatingKey
        case leafCount, viewedLeafCount
        case media = "Media"
        case genre = "Genre"
        case country = "Country"
    }

    /// Decode a value that Plex may return as either String or Int.
    private static func decodeFlexibleString(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let str = try? container.decode(String.self, forKey: key) { return str }
        if let num = try? container.decode(Int.self, forKey: key) { return String(num) }
        return nil
    }

    /// Decode a numeric value Plex may return as Double, Int, or String.
    private static func decodeFlexibleDouble(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = Self.decodeFlexibleString(from: c, forKey: .ratingKey) ?? ""
        key = try? c.decodeIfPresent(String.self, forKey: .key)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        titleSort = try? c.decodeIfPresent(String.self, forKey: .titleSort)
        originalTitle = try? c.decodeIfPresent(String.self, forKey: .originalTitle)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        studio = try? c.decodeIfPresent(String.self, forKey: .studio)
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        index = try? c.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try? c.decodeIfPresent(Int.self, forKey: .parentIndex)
        duration = try? c.decodeIfPresent(Int.self, forKey: .duration)
        addedAt = try? c.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try? c.decodeIfPresent(Int.self, forKey: .updatedAt)
        viewCount = try? c.decodeIfPresent(Int.self, forKey: .viewCount)
        lastViewedAt = try? c.decodeIfPresent(Int.self, forKey: .lastViewedAt)
        userRating = Self.decodeFlexibleDouble(from: c, forKey: .userRating)
        thumb = try? c.decodeIfPresent(String.self, forKey: .thumb)
        art = try? c.decodeIfPresent(String.self, forKey: .art)
        parentThumb = try? c.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentThumb = try? c.decodeIfPresent(String.self, forKey: .grandparentThumb)
        grandparentArt = try? c.decodeIfPresent(String.self, forKey: .grandparentArt)
        parentTitle = try? c.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentTitle = try? c.decodeIfPresent(String.self, forKey: .grandparentTitle)
        parentRatingKey = Self.decodeFlexibleString(from: c, forKey: .parentRatingKey)
        grandparentRatingKey = Self.decodeFlexibleString(from: c, forKey: .grandparentRatingKey)
        leafCount = try? c.decodeIfPresent(Int.self, forKey: .leafCount)
        viewedLeafCount = try? c.decodeIfPresent(Int.self, forKey: .viewedLeafCount)
        media = try? c.decodeIfPresent([PlexMedia].self, forKey: .media)
        genre = try? c.decodeIfPresent([PlexTag].self, forKey: .genre)
        country = try? c.decodeIfPresent([PlexTag].self, forKey: .country)
    }
}

// MARK: - Media & Stream

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
}

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
}

struct PlexStream: Codable, Sendable, Hashable {
    let id: Int?
    let streamType: Int?
    let codec: String?
    let channels: Int?
    let bitrate: Int?
    let bitDepth: Int?
    let samplingRate: Int?

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, channels, bitrate, bitDepth, samplingRate
    }

    init(
        id: Int? = nil,
        streamType: Int? = nil,
        codec: String? = nil,
        channels: Int? = nil,
        bitrate: Int? = nil,
        bitDepth: Int? = nil,
        samplingRate: Int? = nil
    ) {
        self.id = id
        self.streamType = streamType
        self.codec = codec
        self.channels = channels
        self.bitrate = bitrate
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func decodeFlexibleInt(_ key: CodingKeys) -> Int? {
            if let value = try? c.decode(Int.self, forKey: key) { return value }
            if let value = try? c.decode(String.self, forKey: key), let intValue = Int(value) { return intValue }
            return nil
        }

        id = decodeFlexibleInt(.id)
        streamType = decodeFlexibleInt(.streamType)
        codec = try? c.decodeIfPresent(String.self, forKey: .codec)
        channels = decodeFlexibleInt(.channels)
        bitrate = decodeFlexibleInt(.bitrate)
        bitDepth = decodeFlexibleInt(.bitDepth)
        samplingRate = decodeFlexibleInt(.samplingRate)
    }
}

struct PlexTag: Codable, Sendable, Hashable {
    let tag: String?
}

// MARK: - Hub (for search results)

struct Hub: Codable, Sendable, Identifiable {
    let hubIdentifier: String?
    let title: String?
    let type: String?
    let size: Int?
    let metadata: [PlexMetadata]?

    var id: String { hubIdentifier ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case hubIdentifier, title, type, size
        case metadata = "Metadata"
    }
}

// MARK: - Plex Account / Server

struct PlexServer: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let uri: String
    let machineIdentifier: String
    let accessToken: String
    /// All known connections for this server — used to re-probe when network conditions change.
    let connections: [PlexConnection]

    var id: String { machineIdentifier }

    var baseURL: URL {
        URL(string: uri)!
    }
}

struct PlexPin: Decodable, Sendable {
    let id: Int
    let code: String
    let authToken: String?

    enum CodingKeys: String, CodingKey {
        case id, code
        // Plex v2 JSON uses camelCase "authToken"
        case authToken
        // Plex v1 / some endpoints use snake_case "auth_token"
        case authTokenSnake = "auth_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        // Try camelCase first, then snake_case
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
            ?? container.decodeIfPresent(String.self, forKey: .authTokenSnake)
    }
}

struct PlexPinResponse: Decodable, Sendable {
    let id: Int
    let code: String
    let authToken: String?

    enum CodingKeys: String, CodingKey {
        case id, code
        case authToken
        case authTokenSnake = "auth_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
            ?? container.decodeIfPresent(String.self, forKey: .authTokenSnake)
    }
}

struct PlexResource: Decodable, Sendable {
    let name: String?
    let provides: String?
    let clientIdentifier: String?
    let accessToken: String?
    let owned: Bool?
    let connections: [PlexConnection]?

    var isServer: Bool { provides?.contains("server") == true }
    var displayName: String { name ?? "Unknown Server" }
}

struct PlexConnection: Codable, Sendable, Hashable {
    let uri: String?
    let local: Bool?
    let address: String?
    let port: Int?
    let `protocol`: String?
    let relay: Bool?
}

// MARK: - Playlist

struct PlexPlaylist: Codable, Sendable, Identifiable, Hashable {
    let ratingKey: String
    let key: String?
    let type: String?
    let title: String
    let summary: String?
    let smart: Bool?
    let playlistType: String?
    let composite: String?
    let duration: Int?
    let leafCount: Int?
    let addedAt: Int?
    let updatedAt: Int?

    var id: String { ratingKey }
    var isMusicPlaylist: Bool { playlistType == "audio" }
}
