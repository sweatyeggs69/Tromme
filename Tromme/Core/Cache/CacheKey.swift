import Foundation
import CryptoKit

enum CacheKey {
    static func lyrics(title: String, artist: String) -> String {
        "lyrics_v3_\(artist)_\(title)"
    }
    static func lastFMTopTracks(artist: String) -> String {
        "lastfm_toptracks_\(artist.lowercased())"
    }
}
