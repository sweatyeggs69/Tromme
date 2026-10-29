import Foundation

/// Heavy music (metal, metalcore, post-hardcore and the like) tends to have intros and outros
/// that are part of the song's identity, so Auto Mix leaves them whole.
enum HeavyGenre {
    private static let keywords = ["metal", "core", "screamo", "djent", "thrash", "sludge", "doom"]

    /// Checks the track's genres and styles, then its album's, then its artist's.
    static func matches(_ track: PlexMetadata, client: PlexAPIClient?, server: PlexServer?) async -> Bool {
        if isHeavy(track) { return true }
        guard let client, let server else { return false }
        for key in [track.parentRatingKey, track.grandparentRatingKey].compactMap({ $0 }) {
            if let parent = try? await client.cachedMetadata(server: server, ratingKey: key), isHeavy(parent) {
                return true
            }
        }
        return false
    }

    private static func isHeavy(_ item: PlexMetadata) -> Bool {
        ((item.genre ?? []) + (item.style ?? [])).contains { tag in
            guard let name = tag.tag?.lowercased() else { return false }
            return keywords.contains { name.contains($0) }
        }
    }
}
