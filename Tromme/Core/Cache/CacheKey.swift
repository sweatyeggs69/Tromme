import Foundation
import CryptoKit

enum CacheKey {
    static func lyrics(title: String, artist: String) -> String {
        "lyrics_v5_\(artist)_\(title)"
    }
    static func lastFMTopTracks(artist: String) -> String {
        "lastfm_toptracks_\(artist.lowercased())"
    }
    static func artistLogo(mbid: String?, name: String) -> String {
        "artistlogo_v2_\(mbid ?? "name:" + name.lowercased())"
    }
}
