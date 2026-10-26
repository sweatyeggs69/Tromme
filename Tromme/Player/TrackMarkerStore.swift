import Foundation
import Observation

/// Per-track start/stop markers, keyed by Plex rating key. Local only: Plex has no
/// documented marker type for music.
@Observable @MainActor
final class TrackMarkerStore {
    private var markers: [String: TrackMarkers] = [:]

    init() {
        load()
    }

    func markers(for ratingKey: String) -> TrackMarkers {
        markers[ratingKey] ?? TrackMarkers()
    }

    /// Where playback begins; nil when the track has no start marker.
    func start(for ratingKey: String) -> TimeInterval? {
        markers[ratingKey]?.start
    }

    /// Where playback ends; nil when the track has no stop marker.
    func stop(for ratingKey: String) -> TimeInterval? {
        markers[ratingKey]?.stop
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
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([String: TrackMarkers].self, from: data) else { return }
        markers = loaded
    }
}
