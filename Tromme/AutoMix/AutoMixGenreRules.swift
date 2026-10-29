import Foundation

/// Every genre rule for Auto Mix in one place: songs whose Plex genre or style tags match
/// these lists get a plain crossfade instead of a lyric-timed mix, so their intros and outros
/// play whole. Keywords match any part of a tag ("hardcore" covers post-hardcore), ignoring
/// case. Songs with no tags at all crossfade too.
enum AutoMixGenreRules {
    private static let genres = [
        "metal", "hardcore", "metalcore", "deathcore", "mathcore", "grindcore", "crunkcore",
        "screamo", "djent", "thrash", "sludge", "doom", "industrial",
    ]

    /// Why the song should crossfade ("genre:Metalcore", "untagged"), or nil to
    /// mix it normally. Checks the track's tags, then its album's, then its artist's. A song with
    /// no tags anywhere (brand new, or missing metadata) also crossfades, since nothing says a
    /// mix suits it.
    static func crossfadeReason(_ track: PlexMetadata, client: PlexAPIClient?, server: PlexServer?) async -> String? {
        var sawTags = hasTags(track)
        if let match = match(in: track) { return match }
        if let client, let server {
            for key in [track.parentRatingKey, track.grandparentRatingKey].compactMap({ $0 }) {
                guard let parent = try? await client.cachedMetadata(server: server, ratingKey: key) else { continue }
                sawTags = sawTags || hasTags(parent)
                if let match = match(in: parent) { return match }
            }
        }
        return sawTags ? nil : "untagged"
    }

    private static func hasTags(_ item: PlexMetadata) -> Bool {
        ((item.genre ?? []) + (item.style ?? []) + (item.mood ?? [])).contains { !($0.tag ?? "").isEmpty }
    }

    private static func match(in item: PlexMetadata) -> String? {
        let tags = ((item.genre ?? []) + (item.style ?? [])).compactMap(\.tag)
        if let tag = tags.first(where: { tag in genres.contains { tag.lowercased().contains($0) } }) {
            return "genre:\(tag)"
        }
        return nil
    }

    /// Live albums and DJ mixes already flow from track to track (crowd noise, segues), so
    /// their songs are never mixed, even out of album order.
    static func isLiveOrMixRelease(_ track: PlexMetadata, client: PlexAPIClient?, server: PlexServer?) async -> Bool {
        guard let client, let server, let albumKey = track.parentRatingKey,
              let album = try? await client.cachedMetadata(server: server, ratingKey: albumKey) else { return false }
        return (album.subformat ?? []).compactMap { $0.tag?.lowercased() }.contains { format in
            format.contains("live") || format.contains("dj") || (format.contains("mix") && !format.contains("remix") && !format.contains("mixtape"))
        }
    }
}
