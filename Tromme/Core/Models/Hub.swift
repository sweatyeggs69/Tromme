import Foundation

struct Hub: Codable, Sendable, Identifiable {
    let hubIdentifier: String?
    let title: String?
    let type: String?
    let size: Int?
    let metadata: [PlexMetadata]?

    var id: String { hubIdentifier ?? (type ?? "hub") + "_" + (title ?? "unknown") }

    init(hubIdentifier: String?, title: String?, type: String?, size: Int?, metadata: [PlexMetadata]?) {
        self.hubIdentifier = hubIdentifier
        self.title = title
        self.type = type
        self.size = size
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case hubIdentifier, title, type, size
        case metadata = "Metadata"
    }
}
