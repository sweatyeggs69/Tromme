import Foundation

/// Mirrors user preferences between UserDefaults and iCloud key-value storage so they
/// survive a reinstall and follow the user to a new device. Only the keys listed in
/// `syncedKeys` are mirrored; tokens, caches, queues and download records never leave the device.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    /// Plain preference keys (same strings the `@AppStorage` properties use).
    static let syncedKeys: [String] = [
        "infiniteModeActive",
        "playbackBadgeMode",
        "disableCellularTranscoding",
        "soundCheckEnabled",
        "soundCheckGainSource",
        "magicMixSeedCap",
        "autoDownloadEnabled",
        "autoDownloadMode",
        "dynamicDownloadLimit",
        "downloadQuality",
        "animatedArtworkEnabled",
        "leftAlignLyrics",
        "showFeaturedSection",
        "featuredBannerSize",
        "showPopularTracks",
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

    /// Call once at launch, before the UI reads any preference.
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
        // Cloud wins where it has a value (fresh install); otherwise seed it from this device.
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
