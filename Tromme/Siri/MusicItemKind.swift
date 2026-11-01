import AppIntents

enum MusicItemKind: String, Sendable {
    case artist, album, track, playlist

    var label: LocalizedStringResource {
        switch self {
        case .artist: "Artist"
        case .album: "Album"
        case .track: "Song"
        case .playlist: "Playlist"
        }
    }
}
