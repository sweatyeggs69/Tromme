import Foundation

/// Optional start and stop times, in seconds, that trim a track's intro and outro.
struct TrackMarkers: Codable, Equatable, Sendable {
    var start: TimeInterval?
    var stop: TimeInterval?

    var isEmpty: Bool { start == nil && stop == nil }
}
