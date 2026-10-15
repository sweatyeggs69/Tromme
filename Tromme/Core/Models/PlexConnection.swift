import Foundation

struct PlexConnection: Codable, Sendable, Hashable {
    let uri: String?
    let local: Bool?
    let address: String?
    let port: Int?
    let `protocol`: String?
    let relay: Bool?
}
