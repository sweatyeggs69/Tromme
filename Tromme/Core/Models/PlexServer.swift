import Foundation

struct PlexServer: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let uri: String
    let machineIdentifier: String
    let accessToken: String
    /// All known connections for this server — used to re-probe when network conditions change.
    let connections: [PlexConnection]

    var id: String { machineIdentifier }

    var baseURL: URL? {
        URL(string: uri)
    }
}
