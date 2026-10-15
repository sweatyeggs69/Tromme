import Foundation

/// Last-fetched server hubs, one JSON file per server and library, so Home can show them instantly.
enum PlexHubCache {
    private static func fileURL(serverURI: String, sectionId: String) -> URL {
        let raw = "\(serverURI)|\(sectionId)"
        let safe = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        return URL.cachesDirectory.appending(path: "plexHubs-\(safe).json")
    }

    static func load(serverURI: String, sectionId: String) -> [PlexHub] {
        let url = fileURL(serverURI: serverURI, sectionId: sectionId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PlexHub].self, from: data)) ?? []
    }

    static func save(_ hubs: [PlexHub], serverURI: String, sectionId: String) {
        let url = fileURL(serverURI: serverURI, sectionId: sectionId)
        guard let data = try? JSONEncoder().encode(hubs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
