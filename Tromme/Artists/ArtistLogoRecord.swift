import Foundation

/// What is cached per artist: the fanart.tv logo URL, or nil when the artist has none
/// (cached too, so artists without a logo aren't looked up on every visit).
struct ArtistLogoRecord: Codable, Sendable {
    let logoURL: String?
}
