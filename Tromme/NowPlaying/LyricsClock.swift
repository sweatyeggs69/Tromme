import Foundation

struct LyricsClock: Equatable {
    var anchorTime: TimeInterval = 0
    var anchorDate: Date = .now
    var isPlaying = false
    var advance: TimeInterval = 0

    static let defaultAdvance: TimeInterval = 0.15

    private static let maxExtrapolation: TimeInterval = 1

    func time(at date: Date = .now) -> TimeInterval {
        guard isPlaying else { return anchorTime + advance }
        return anchorTime + advance + min(max(date.timeIntervalSince(anchorDate), 0), Self.maxExtrapolation)
    }
}
