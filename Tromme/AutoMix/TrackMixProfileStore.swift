import Foundation

/// Mix profiles saved as small JSON files in Application Support, one per song.
enum TrackMixProfileStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MixProfiles", isDirectory: true)
    }

    private static func file(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    /// A cached profile, if it is current and matches the song's length (a replaced file
    /// with a different length is analysed again).
    static func load(key: String, duration: TimeInterval?) -> TrackMixProfile? {
        guard let data = try? Data(contentsOf: file(for: key)),
              let profile = try? JSONDecoder().decode(TrackMixProfile.self, from: data),
              profile.version == TrackMixProfile.currentVersion else { return nil }
        if let duration, duration > 0, abs(profile.duration - duration) > 3 { return nil }
        return profile
    }

    static func save(_ profile: TrackMixProfile, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: file(for: key), options: .atomic)
    }
}
