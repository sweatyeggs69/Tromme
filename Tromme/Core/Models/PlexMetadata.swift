import Foundation

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
    var parentThumb: String?
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
    let similar: [PlexTag]?
    let originallyAvailableAt: String?
    var playlistItemID: Int? = nil

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
        case leafCount, viewedLeafCount, originallyAvailableAt, playlistItemID
        case media = "Media"
        case subformat = "Subformat"
        case genre = "Genre"
        case style = "Style"
        case country = "Country"
        case similar = "Similar"
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
        self.subformat = nil; self.similar = nil; self.originallyAvailableAt = nil
    }

    /// Convenience init for constructing a minimal album or artist from offline records.
    init(ratingKey: String, title: String, type: String, parentTitle: String?, thumb: String?) {
        self.ratingKey = ratingKey; self.title = title; self.type = type; self.thumb = thumb
        self.parentTitle = parentTitle
        self.subtype = nil; self.key = nil; self.titleSort = nil; self.originalTitle = nil
        self.summary = nil; self.studio = nil; self.year = nil; self.index = nil
        self.parentIndex = nil; self.duration = nil; self.addedAt = nil; self.updatedAt = nil
        self.viewCount = nil; self.lastViewedAt = nil; self.userRating = nil; self.art = nil
        self.parentThumb = nil; self.grandparentThumb = nil; self.grandparentArt = nil
        self.grandparentTitle = nil; self.parentRatingKey = nil; self.grandparentRatingKey = nil
        self.leafCount = nil; self.viewedLeafCount = nil; self.media = nil
        self.genre = nil; self.style = nil; self.country = nil
        self.subformat = nil; self.similar = nil; self.originallyAvailableAt = nil
    }

    /// Convenience init for recreating a downloaded track from a persisted record.
    init(
        ratingKey: String,
        title: String,
        grandparentTitle: String?,
        parentTitle: String?,
        parentRatingKey: String?,
        thumbPath: String?,
        durationMs: Int?
    ) {
        self.ratingKey = ratingKey
        self.title = title
        self.type = "track"
        self.thumb = thumbPath
        self.subtype = nil
        self.key = nil; self.titleSort = nil; self.originalTitle = nil; self.summary = nil
        self.studio = nil; self.year = nil; self.index = nil; self.parentIndex = nil
        self.duration = durationMs; self.addedAt = nil; self.updatedAt = nil; self.viewCount = nil
        self.lastViewedAt = nil; self.userRating = nil; self.art = nil
        self.parentThumb = thumbPath
        self.grandparentThumb = nil; self.grandparentArt = nil
        self.parentTitle = parentTitle
        self.grandparentTitle = grandparentTitle
        self.parentRatingKey = parentRatingKey; self.grandparentRatingKey = nil
        self.leafCount = nil; self.viewedLeafCount = nil; self.media = nil
        self.genre = nil; self.style = nil; self.country = nil
        self.subformat = nil; self.similar = nil; self.originallyAvailableAt = nil
    }

    // MARK: - Navigation Stubs
    //
    // These factories build minimal metadata objects for use as NavigationLink values
    // when navigating from a track row context menu. They avoid repeating 25-argument
    // initialisers at every call site.

    /// Returns a minimal album metadata object suitable for navigation, built from a track.
    static func albumStub(from track: PlexMetadata) -> PlexMetadata? {
        guard let albumKey = track.parentRatingKey else { return nil }
        return PlexMetadata(
            ratingKey: albumKey,
            title: track.parentTitle ?? "",
            type: "album",
            parentTitle: track.grandparentTitle ?? track.artistName,
            thumb: track.parentThumb ?? track.thumb
        )
    }

    /// Returns a minimal artist metadata object suitable for navigation, built from a track.
    static func artistStub(from track: PlexMetadata) -> PlexMetadata? {
        guard let artistKey = track.grandparentRatingKey else { return nil }
        return PlexMetadata(
            ratingKey: artistKey,
            title: track.grandparentTitle ?? track.artistName,
            type: "artist",
            thumb: track.grandparentThumb
        )
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
        similar = try? c.decodeIfPresent([PlexTag].self, forKey: .similar)
        originallyAvailableAt = try? c.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        playlistItemID = try? c.decodeIfPresent(Int.self, forKey: .playlistItemID)
    }
}
