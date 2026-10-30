import Foundation

struct TrackMarkers: Codable, Equatable, Sendable {
    var start: TimeInterval?
    var stop: TimeInterval?

    var isEmpty: Bool { start == nil && stop == nil }
}
