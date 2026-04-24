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
    let subtype: String?
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
    let style: [PlexTag]?
    let country: [PlexTag]?
    let subformat: [PlexTag]?
    let originallyAvailableAt: String?

    var id: String { ratingKey }

    /// The release format label (e.g. "Single", "EP"). Returns nil for standard albums.
    var formatLabel: String? {
        guard let tag = subformat?.first?.tag, !tag.isEmpty else { return nil }
        let lower = tag.lowercased()
        if lower == "album" { return nil }
        return tag.capitalized
    }

    /// Whether this release is a single or EP, based on subformat tag or track count heuristic.
    var isSingleOrEP: Bool {
        if let tag = subformat?.first?.tag?.lowercased() {
            return tag == "single" || tag == "ep"
        }
        // Heuristic: releases with 1-6 tracks are likely singles/EPs
        if let count = leafCount {
            return count <= 6
        }
        return false
    }

    var durationFormatted: String {
        guard let duration else { return "" }
        let seconds = duration / 1000
        let min = seconds / 60
        let sec = seconds % 60
        return String(format: "%d:%02d", min, sec)
    }

    var releaseYear: String {
        if let date = originallyAvailableAt, date.count >= 4 {
            return String(date.prefix(4))
        }
        return year.map(String.init) ?? "Unknown Year"
    }

    var artistName: String {
        grandparentTitle ?? parentTitle ?? ""
    }

    /// Display name for UI. Prefer track-level artist credit when Plex provides one.
    var artistDisplayName: String {
        let trackLevelArtist = (originalTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trackLevelArtist.isEmpty {
            return trackLevelArtist
        }
        return artistName
    }

    var albumName: String {
        parentTitle ?? ""
    }
}

extension PlexMetadata {
    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, subtype, title, titleSort, originalTitle, summary, studio
        case year, index, parentIndex, duration, addedAt, updatedAt
        case viewCount, lastViewedAt, userRating
        case thumb, art, parentThumb, grandparentThumb, grandparentArt
        case parentTitle, grandparentTitle, parentRatingKey, grandparentRatingKey
        case leafCount, viewedLeafCount, originallyAvailableAt
        case media = "Media"
        case subformat = "Subformat"
        case genre = "Genre"
        case style = "Style"
        case country = "Country"
    }

    init(ratingKey: String, title: String, type: String? = nil, thumb: String? = nil) {
        self.ratingKey = ratingKey
        self.title = title
        self.type = type
        self.thumb = thumb
        self.subtype = nil
        self.key = nil; self.titleSort = nil; self.originalTitle = nil; self.summary = nil
        self.studio = nil; self.year = nil; self.index = nil; self.parentIndex = nil
        self.duration = nil; self.addedAt = nil; self.updatedAt = nil; self.viewCount = nil
        self.lastViewedAt = nil; self.userRating = nil; self.art = nil; self.parentThumb = nil
        self.grandparentThumb = nil; self.grandparentArt = nil; self.parentTitle = nil
        self.grandparentTitle = nil; self.parentRatingKey = nil; self.grandparentRatingKey = nil
        self.leafCount = nil; self.viewedLeafCount = nil; self.media = nil
        self.genre = nil; self.style = nil; self.country = nil
        self.subformat = nil; self.originallyAvailableAt = nil
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
        subtype = try? c.decodeIfPresent(String.self, forKey: .subtype)
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
        style = try? c.decodeIfPresent([PlexTag].self, forKey: .style)
        country = try? c.decodeIfPresent([PlexTag].self, forKey: .country)
        subformat = try? c.decodeIfPresent([PlexTag].self, forKey: .subformat)
        originallyAvailableAt = try? c.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
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

    var id: String { hubIdentifier ?? (type ?? "hub") + "_" + (title ?? "unknown") }

    init(hubIdentifier: String?, title: String?, type: String?, size: Int?, metadata: [PlexMetadata]?) {
        self.hubIdentifier = hubIdentifier
        self.title = title
        self.type = type
        self.size = size
        self.metadata = metadata
    }

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

    var baseURL: URL? {
        URL(string: uri)
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
    let thumb: String?
    let composite: String?
    let duration: Int?
    let leafCount: Int?
    let addedAt: Int?
    let updatedAt: Int?

    var id: String { ratingKey }
    var isMusicPlaylist: Bool { playlistType == "audio" }
}
