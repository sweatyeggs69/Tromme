import Foundation

/// HLS URLs for an album's Apple Music animated artwork.
struct AnimatedArtwork: Sendable {
    let square: URL?
    let tall: URL?

    var isEmpty: Bool { square == nil && tall == nil }
}
