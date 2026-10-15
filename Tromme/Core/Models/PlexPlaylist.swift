import Foundation

struct PlexPlaylist: Codable, Sendable, Identifiable, Hashable {
    let ratingKey: String
    let key: String?
    let type: String?
    let title: String
    let summary: String?
    let smart: Bool?
    let playlistType: String?
    let thumb: String?
    let composite: String?
    let duration: Int?
    let leafCount: Int?
    let addedAt: Int?
    let updatedAt: Int?

    var id: String { ratingKey }
    var isMusicPlaylist: Bool { playlistType == "audio" }
}
