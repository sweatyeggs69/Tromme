import Foundation

/// Where a set of lyrics came from, shown under the lyrics so the user can tell
/// which match is on screen (and that a block moved on to a different one).
enum LyricsSource: String, Codable, Sendable {
    case lrcRed
    case lrclib

    var displayName: String {
        switch self {
        case .lrcRed: "lrc.red"
        case .lrclib: "LRCLIB"
        }
    }
}
