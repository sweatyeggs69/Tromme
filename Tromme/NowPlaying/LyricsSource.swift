import Foundation

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
