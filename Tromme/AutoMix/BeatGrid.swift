import Foundation

struct BeatGrid: Sendable {
    let bpm: Double
    /// Track time of one beat inside the window.
    let referenceBeat: TimeInterval

    var period: TimeInterval { 60 / bpm }

    /// The first beat at or after `time`.
    func beat(atOrAfter time: TimeInterval) -> TimeInterval {
        let steps = ceil((time - referenceBeat) / period)
        return referenceBeat + steps * period
    }

    /// The beat closest to `time`.
    func nearestBeat(to time: TimeInterval) -> TimeInterval {
        let steps = ((time - referenceBeat) / period).rounded()
        return referenceBeat + steps * period
    }
}
