import Foundation

struct PlexResource: Decodable, Sendable {
    let name: String?
    let provides: String?
    let clientIdentifier: String?
    let accessToken: String?
    let owned: Bool?
    let connections: [PlexConnection]?

    var isServer: Bool { provides?.contains("server") == true }
    var displayName: String { name ?? "Unknown Server" }
}
