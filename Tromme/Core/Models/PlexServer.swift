import Foundation

struct PlexServer: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let uri: String
    let machineIdentifier: String
    let accessToken: String
    let connections: [PlexConnection]
    var isOwned: Bool? = nil

    var canEditMetadata: Bool { isOwned != false }

    var id: String { machineIdentifier }

    var baseURL: URL? {
        URL(string: uri)
    }
}
