import Foundation

enum HomeHubCache {
    private struct Snapshot: Codable {
        let scope: String
        let hubs: [Hub]
    }

    private struct RecentTracksSnapshot: Codable {
        let scope: String
        let tracks: [PlexMetadata]
    }

    private static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "TrommeState", directoryHint: .isDirectory)
            .appending(path: name)
    }

    private static var fileURL: URL { url("homeHubs.json") }
    private static var recentTracksURL: URL { url("homeRecentTracks.json") }

    static func loadRecentTracks(scope: String) -> [PlexMetadata] {
        guard let data = try? Data(contentsOf: recentTracksURL),
              let snapshot = try? JSONDecoder().decode(RecentTracksSnapshot.self, from: data),
              snapshot.scope == scope else { return [] }
        return snapshot.tracks
    }

    static func saveRecentTracks(_ tracks: [PlexMetadata], scope: String) {
        let url = recentTracksURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(RecentTracksSnapshot(scope: scope, tracks: tracks)) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
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
