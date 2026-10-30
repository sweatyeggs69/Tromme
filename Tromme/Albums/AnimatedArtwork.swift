import Foundation

struct AnimatedArtwork: Sendable {
    let square: URL?
    let tall: URL?

    var isEmpty: Bool { square == nil && tall == nil }
}
