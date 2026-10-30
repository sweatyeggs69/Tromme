import Foundation

@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    static let syncedKeys: [String] = [
        "infiniteModeActive",
        "playbackBadgeMode",
        "disableCellularTranscoding",
        "magicMixSeedCap",
        "autoMixEnabled",
        "crossfadeSeconds",
        "autoMixNoticeShown",
        "crossfadeNoticeShown",
        "autoDownloadEnabled",
        "autoDownloadMode",
        "dynamicDownloadLimit",
        "downloadQuality",
        "animatedArtworkEnabled",
        "leftAlignLyrics",
        "showFeaturedSection",
        "featuredBannerSize",
        "hideEmptySections",
        "artistsViewMode",
        "artistAllTracksSortNewestFirst",
        "allSongsSortOrder",
        "allAlbumsViewMode",
        "allAlbumsSortOrder"
    ]

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.pullFromCloud(only: keys) }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushToCloud() }
        }

        cloud.synchronize()
        pullFromCloud(only: nil)
        pushToCloud()
    }

    private func pullFromCloud(only changed: [String]?) {
        for key in Self.syncedKeys where changed?.contains(key) ?? true {
            guard let value = cloud.object(forKey: key) else { continue }
            if let local = defaults.object(forKey: key), (local as AnyObject).isEqual(value) { continue }
            defaults.set(value, forKey: key)
        }
    }

    private func pushToCloud() {
        var didChange = false
        for key in Self.syncedKeys {
            guard let local = defaults.object(forKey: key) else { continue }
            if let remote = cloud.object(forKey: key), (remote as AnyObject).isEqual(local) { continue }
            cloud.set(local, forKey: key)
            didChange = true
        }
        if didChange { cloud.synchronize() }
    }
}
