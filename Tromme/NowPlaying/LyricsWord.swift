import Foundation
import Observation

struct LyricsWord: Sendable {
    let time: TimeInterval
    let endTime: TimeInterval
    /// Includes any trailing space, so joining a line's words rebuilds its text.
    let text: String
}
