import Foundation

enum HomeHubCache {
    private struct Snapshot: Codable {
        let scope: String
        let hubs: [Hub]
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "TrommeState", directoryHint: .isDirectory)
            .appending(path: "homeHubs.json")
    }

    static func load(scope: String) -> [Hub] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.scope == scope else { return [] }
        return snapshot.hubs
    }

    static func save(_ hubs: [Hub], scope: String) {
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(Snapshot(scope: scope, hubs: hubs)) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
