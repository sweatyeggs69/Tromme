import Foundation

struct LibrarySection: Codable, Sendable, Identifiable, Hashable {
    let key: String
    let type: String
    let title: String
    let agent: String?
    let scanner: String?
    let language: String?
    let uuid: String?
    let updatedAt: Int?
    let scannedAt: Int?
    let thumb: String?
    let art: String?

    var id: String { key }
    var isMusicLibrary: Bool { type == "artist" }
}

extension LibrarySection {
    enum CodingKeys: String, CodingKey {
        case key, type, title, agent, scanner, language, uuid
        case updatedAt, scannedAt, thumb, art
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // key and type can come as String or Int from Plex
        if let str = try? container.decode(String.self, forKey: .key) {
            key = str
        } else if let num = try? container.decode(Int.self, forKey: .key) {
            key = String(num)
        } else {
            key = ""
        }
        if let str = try? container.decode(String.self, forKey: .type) {
            type = str
        } else if let num = try? container.decode(Int.self, forKey: .type) {
            // Map Plex type numbers: 8 = artist (music library)
            switch num {
            case 1: type = "movie"
            case 2: type = "show"
            case 8: type = "artist"
            case 13: type = "photo"
            default: type = String(num)
            }
        } else {
            type = ""
        }
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        agent = try? container.decodeIfPresent(String.self, forKey: .agent)
        scanner = try? container.decodeIfPresent(String.self, forKey: .scanner)
        language = try? container.decodeIfPresent(String.self, forKey: .language)
        uuid = try? container.decodeIfPresent(String.self, forKey: .uuid)
        updatedAt = try? container.decodeIfPresent(Int.self, forKey: .updatedAt)
        scannedAt = try? container.decodeIfPresent(Int.self, forKey: .scannedAt)
        thumb = try? container.decodeIfPresent(String.self, forKey: .thumb)
        art = try? container.decodeIfPresent(String.self, forKey: .art)
    }
}
