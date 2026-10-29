import Foundation

/// Published when a mix starts, so Now Playing can play its transition animation.
struct AutoMixTransition: Identifiable, Equatable, Sendable {
    let id = UUID()
    let duration: TimeInterval
    let isBeatMatched: Bool
}
