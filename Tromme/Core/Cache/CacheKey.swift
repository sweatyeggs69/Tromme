import Foundation
import CryptoKit

enum CacheKey {
    static func lyrics(title: String, artist: String) -> String {
        "lyrics_v5_\(artist)_\(title)"
    }
}
