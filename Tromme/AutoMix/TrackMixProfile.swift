import Foundation

/// Whole-song analysis for Auto Mix: loudness over time, the beat in overlapping windows,
/// and where an instrumental or quieter outro begins. Computed once per song and cached.
struct TrackMixProfile: Codable, Sendable {
    static let currentVersion = 1
    static let frameDuration: TimeInterval = 0.1
    static let beatWindow: TimeInterval = 10
    static let beatHop: TimeInterval = 5

    let version: Int
    let duration: TimeInterval
    /// RMS level of each `frameDuration` frame in whole dBFS.
    let levels: [Int8]
    /// Beat estimates for `beatWindow`-long windows every `beatHop` seconds.
    let beats: [WindowBeat]
    /// Where the closing section starts when it drops its beat or gets clearly quieter.
    let outroStart: TimeInterval?

    struct WindowBeat: Codable, Sendable {
        let start: TimeInterval
        let bpm: Double?
        let referenceBeat: TimeInterval?

        var grid: BeatGrid? {
            guard let bpm, let referenceBeat else { return nil }
            return BeatGrid(bpm: bpm, referenceBeat: referenceBeat)
        }
    }

    /// The part of the song between `start` and `end`, in the shape the planner reads.
    /// `edge` picks which end's beat counts as the transition beat.
    func window(from start: TimeInterval, to end: TimeInterval, edge: AutoMixAnalyzer.Edge) -> AutoMixWindowAnalysis {
        let lower = max(0, min(levels.count, Int(max(0, start) / Self.frameDuration)))
        let upper = max(lower, min(levels.count, Int((min(end, duration) / Self.frameDuration).rounded(.up))))
        let slice = levels[lower..<upper].map { Float($0) }

        let inside = beats.filter { $0.start >= start - 2.5 && $0.start + Self.beatWindow <= end + 2.5 }
        let grids = inside.compactMap(\.grid).sorted { $0.bpm < $1.bpm }
        let typical = grids.isEmpty ? nil : grids[grids.count / 2]

        let edgeEntry: WindowBeat? = switch edge {
        case .end: beats.last { $0.start + Self.beatWindow <= end + 2.5 }
        case .start: beats.first { $0.start >= start - 2.5 }
        }
        return AutoMixWindowAnalysis(
            windowStart: Double(lower) * Self.frameDuration,
            frameDuration: Self.frameDuration,
            levels: slice,
            beat: typical,
            edgeBeat: edgeEntry?.grid
        )
    }
}
