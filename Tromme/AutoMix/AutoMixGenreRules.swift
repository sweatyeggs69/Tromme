import Foundation

/// Every genre rule for Auto Mix in one place: which Plex genre, style or mood tags change how
/// a song is mixed. Genre and style keywords match any part of a tag ("core" covers metalcore
/// and post-hardcore); moods match whole, since words like "intense" are too broad to share.
/// Matching is case-insensitive.
enum AutoMixGenreRules {
    enum Treatment: Sendable {
        /// Never mixed; the song changes with a normal gapless transition.
        case noMix
        /// The intro and outro are part of the song's identity: no intro skip, no outro
        /// shortening, just a short crossfade at the seam.
        case keepIntroAndOutro
    }

    /// Checked in order; the first rule that matches wins.
    /// Songs with no tags at all are also `.noMix`; see `treatment(for:client:server:)`.
    private static let rules: [(treatment: Treatment, genres: [String], moods: [String])] = [
        (.noMix, [], []),
        (.keepIntroAndOutro,
         ["metal", "core", "screamo", "djent", "thrash", "sludge", "doom", "grindcore", "industrial"],
         ["aggressive", "angry", "brash", "hostile", "menacing", "visceral", "harsh", "volatile",
          "confrontational", "raucous", "fiery"]),
    ]

    /// The treatment for the track's genres, styles and moods, falling back to its album's, then
    /// its artist's. A song with no tags anywhere (brand new, or missing metadata) isn't mixed,
    /// since nothing says whether a mix suits it.
    static func treatment(for track: PlexMetadata, client: PlexAPIClient?, server: PlexServer?) async -> Treatment? {
        var sawTags = hasTags(track)
        if let match = treatment(forTagsOf: track) { return match }
        if let client, let server {
            for key in [track.parentRatingKey, track.grandparentRatingKey].compactMap({ $0 }) {
                guard let parent = try? await client.cachedMetadata(server: server, ratingKey: key) else { continue }
                sawTags = sawTags || hasTags(parent)
                if let match = treatment(forTagsOf: parent) { return match }
            }
        }
        return sawTags ? nil : .noMix
    }

    private static func hasTags(_ item: PlexMetadata) -> Bool {
        ((item.genre ?? []) + (item.style ?? []) + (item.mood ?? [])).contains { !($0.tag ?? "").isEmpty }
    }

    private static func treatment(forTagsOf item: PlexMetadata) -> Treatment? {
        let tags = ((item.genre ?? []) + (item.style ?? [])).compactMap { $0.tag?.lowercased() }
        let moods = Set((item.mood ?? []).compactMap { $0.tag?.lowercased() })
        return rules.first { rule in
            tags.contains { tag in rule.genres.contains { tag.contains($0) } }
                || !moods.isDisjoint(with: rule.moods)
        }?.treatment
    }
}
