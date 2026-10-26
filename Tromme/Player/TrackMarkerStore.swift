import Foundation
import Observation

/// Per-track start/stop markers, keyed by Plex rating key. Local only: Plex has no
/// documented marker type for music. Mirrored to iCloud key-value storage so markers
/// survive a reinstall and follow the user to a new device.
@Observable @MainActor
final class TrackMarkerStore {
    private static let cloudKey = "trackMarkers"

    private var markers: [String: TrackMarkers] = [:]
    private let cloud = NSUbiquitousKeyValueStore.default

    init() {
        load()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullFromCloud() }
        }
        cloud.synchronize()
        // Cloud wins where it has a value (fresh install); otherwise seed it from this device.
        pullFromCloud(merging: true)
        pushToCloud()
    }

    func markers(for ratingKey: String) -> TrackMarkers {
        markers[ratingKey] ?? TrackMarkers()
    }

    /// Where playback begins; nil when the track has no start marker or Plus is off.
    func start(for ratingKey: String) -> TimeInterval? {
        guard PlusStore.cachedIsPlus else { return nil }
        return markers[ratingKey]?.start
    }

    /// Where playback ends; nil when the track has no stop marker or Plus is off.
    func stop(for ratingKey: String) -> TimeInterval? {
        guard PlusStore.cachedIsPlus else { return nil }
        return markers[ratingKey]?.stop
    }

    func setStart(_ seconds: TimeInterval?, for ratingKey: String) {
        update(ratingKey) { $0.start = seconds.flatMap { $0 > 0 ? $0 : nil } }
    }

    func setStop(_ seconds: TimeInterval?, for ratingKey: String) {
        update(ratingKey) { $0.stop = seconds }
    }

    func reset(for ratingKey: String) {
        update(ratingKey) { $0 = TrackMarkers() }
    }

    private func update(_ ratingKey: String, _ change: (inout TrackMarkers) -> Void) {
        var current = markers(for: ratingKey)
        change(&current)
        markers[ratingKey] = current.isEmpty ? nil : current
        persist()
    }

    // MARK: - Persistence

    /// Structured state lives in a disk file, not UserDefaults (see CLAUDE.md).
    private var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "TrommeState", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "trackMarkers.json")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(markers) else { return }
        try? data.write(to: fileURL, options: .atomic)
        pushToCloud()
    }

    private func pushToCloud() {
        guard let data = try? JSONEncoder().encode(markers) else { return }
        cloud.set(data, forKey: Self.cloudKey)
        cloud.synchronize()
    }

    /// `merging` keeps local entries the cloud lacks (launch); otherwise the cloud copy replaces them.
    private func pullFromCloud(merging: Bool = false) {
        guard let data = cloud.data(forKey: Self.cloudKey),
              let remote = try? JSONDecoder().decode([String: TrackMarkers].self, from: data) else { return }
        markers = merging ? markers.merging(remote) { _, cloudValue in cloudValue } : remote
        if let encoded = try? JSONEncoder().encode(markers) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([String: TrackMarkers].self, from: data) else { return }
        markers = loaded
    }
}
