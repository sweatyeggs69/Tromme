import Foundation
import Observation

// MP3 is the only conversion PMS supports over the progressive http transcode
// path — AAC (ADTS) and MP4 targets pass the decision but stream zero bytes.
enum DownloadFormat: String, CaseIterable {
    case original
    case mp3

    static let defaultFormat: DownloadFormat = .mp3

    var displayName: String {
        switch self {
        case .original: "Original (Best Quality)"
        case .mp3: "MP3 (Space Saver)"
        }
    }

    /// Plex container name for the converted download; doubles as the file
    /// extension. `nil` means download the source file untouched.
    var container: String? {
        switch self {
        case .original: nil
        case .mp3: "mp3"
        }
    }
}
