import Foundation

/// Every genre rule for Auto Mix in one place: which Plex genre or style tags change how a
/// song is mixed. Add a keyword to a rule's list to cover more genres. Keywords match any part
/// of a tag, case-insensitively.
enum AutoMixGenreRules {
    enum Treatment: Sendable {
        /// Never mixed; the song changes with a normal gapless transition.
        case noMix
        /// The intro and outro are part of the song's identity: no intro skip, no outro
        /// shortening, just a short crossfade at the seam.
        case keepIntroAndOutro
    }

    /// Checked in order; the first rule that matches wins.
    private static let rules: [(treatment: Treatment, keywords: [String])] = [
        (.noMix, []),
        (.keepIntroAndOutro, ["metal", "core", "screamo", "djent", "thrash", "sludge", "doom"]),
    ]

    /// The treatment for the track's genres and styles, falling back to its album's, then its artist's.
    static func treatment(for track: PlexMetadata, client: PlexAPIClient?, server: PlexServer?) async -> Treatment? {
        if let match = treatment(forTagsOf: track) { return match }
        guard let client, let server else { return nil }
        for key in [track.parentRatingKey, track.grandparentRatingKey].compactMap({ $0 }) {
            if let parent = try? await client.cachedMetadata(server: server, ratingKey: key),
               let match = treatment(forTagsOf: parent) {
                return match
            }
        }
        return nil
    }

    private static func treatment(forTagsOf item: PlexMetadata) -> Treatment? {
        let tags = ((item.genre ?? []) + (item.style ?? [])).compactMap { $0.tag?.lowercased() }
        return rules.first { rule in
            tags.contains { tag in rule.keywords.contains { tag.contains($0) } }
        }?.treatment
    }
}
