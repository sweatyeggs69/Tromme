import Foundation
import CryptoKit

enum CacheKey {
    static func lyrics(title: String, artist: String) -> String {
        "lyrics_v5_\(artist)_\(title)"
    }
    static func lastFMTopTracks(artist: String) -> String {
        "lastfm_toptracks_\(artist.lowercased())"
    }
    static func concerts(artist: String) -> String {
        "concerts_v2_\(artist.lowercased())"
    }
}
