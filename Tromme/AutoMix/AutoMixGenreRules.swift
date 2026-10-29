import Foundation

/// Every genre rule for Auto Mix in one place: songs whose Plex genre, style or mood tags match
/// these lists get a plain crossfade instead of a lyric-timed mix, so their intros and outros
/// play whole. Genre and style keywords match any part of a tag ("core" covers metalcore and
/// post-hardcore); moods match whole, since words like "intense" are too broad to share.
/// Matching is case-insensitive. Songs with no tags at all crossfade too.
enum AutoMixGenreRules {
    private static let genres = [
        "metal", "core", "screamo", "djent", "thrash", "sludge", "doom", "grindcore", "industrial",
    ]
    private static let moods: Set<String> = [
        "aggressive", "angry", "brash", "hostile", "menacing", "visceral", "harsh", "volatile",
        "confrontational", "raucous", "fiery",
    ]

    /// Checks the track's tags, then its album's, then its artist's. A song with no tags anywhere
    /// (brand new, or missing metadata) also crossfades, since nothing says a mix suits it.
    static func wantsCrossfade(_ track: PlexMetadata, client: PlexAPIClient?, server: PlexServer?) async -> Bool {
        var sawTags = hasTags(track)
        if matches(track) { return true }
        if let client, let server {
            for key in [track.parentRatingKey, track.grandparentRatingKey].compactMap({ $0 }) {
                guard let parent = try? await client.cachedMetadata(server: server, ratingKey: key) else { continue }
                sawTags = sawTags || hasTags(parent)
                if matches(parent) { return true }
            }
        }
        return !sawTags
    }

    private static func hasTags(_ item: PlexMetadata) -> Bool {
        ((item.genre ?? []) + (item.style ?? []) + (item.mood ?? [])).contains { !($0.tag ?? "").isEmpty }
    }

    private static func matches(_ item: PlexMetadata) -> Bool {
        let tags = ((item.genre ?? []) + (item.style ?? [])).compactMap { $0.tag?.lowercased() }
        let itemMoods = Set((item.mood ?? []).compactMap { $0.tag?.lowercased() })
        return tags.contains { tag in genres.contains { tag.contains($0) } } || !itemMoods.isDisjoint(with: moods)
    }
}
