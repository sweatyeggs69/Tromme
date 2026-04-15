import Foundation

/// Cache for Plex library API responses. Uses NSCache for memory and
/// JSON files on disk for persistence across launches.
///
/// Strategy: return cached data immediately, then refresh in background.
/// Views call `get()` for cache-first, or `fetch()` to force refresh.
actor LibraryCache {
    static let shared = LibraryCache()

    private let memoryCache = NSCache<NSString, CacheEntry>()
    private let diskURL: URL
    private let defaultTTL: TimeInterval = 300 // 5 minutes for memory freshness
    private let diskTTL: TimeInterval = 86400 // 24 hours for disk staleness
    private let maxDiskSize: Int = 50 * 1024 * 1024 // 50 MB

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskURL = caches.appendingPathComponent("TrommeLibraryCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        memoryCache.countLimit = 100
    }

    // MARK: - Public API

    /// Get cached data if available. Returns nil if no cache exists.
    func get<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> CachedResult<T>? {
        get(type, forKey: key, diskTTL: diskTTL)
    }

    /// Get cached data with a custom disk TTL.
    func get<T: Codable & Sendable>(_ type: T.Type, forKey key: String, diskTTL: TimeInterval) -> CachedResult<T>? {
        // 1. Memory cache
        if let entry = memoryCache.object(forKey: key as NSString),
           let value = entry.decode(as: T.self) {
            let fresh = Date().timeIntervalSince(entry.timestamp) < defaultTTL
            return CachedResult(value: value, isStale: !fresh)
        }

        // 2. Disk cache
        if let entry = loadFromDisk(key: key),
           let value = entry.decode(as: T.self) {
            memoryCache.setObject(entry, forKey: key as NSString)
            let stale = Date().timeIntervalSince(entry.timestamp) > diskTTL
            return CachedResult(value: value, isStale: stale)
        }

        return nil
    }

    /// Store data in both memory and disk.
    func set<T: Codable & Sendable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let entry = CacheEntry(data: data, timestamp: Date())
        memoryCache.setObject(entry, forKey: key as NSString)
        saveToDisk(entry: entry, key: key)
    }

    /// Remove a specific key.
    func remove(forKey key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        let fileURL = diskURL.appendingPathComponent(key.sha256Hash)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Clear all cached data.
    func clearAll() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskURL)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
    }

    /// Clear only memory cache (keeps disk).
    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    // MARK: - Disk Persistence

    private func loadFromDisk(key: String) -> CacheEntry? {
        let fileURL = diskURL.appendingPathComponent(key.sha256Hash)
        guard let fileData = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: fileData)
    }

    private func saveToDisk(entry: CacheEntry, key: String) {
        let fileURL = diskURL.appendingPathComponent(key.sha256Hash)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL, options: .atomic)
        evictIfNeeded()
    }

    /// Remove oldest files if disk cache exceeds size limit.
    private func evictIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }

        var totalSize = 0
        var fileInfos: [(url: URL, size: Int, date: Date)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else { continue }
            totalSize += size
            fileInfos.append((file, size, date))
        }

        guard totalSize > maxDiskSize else { return }

        // Evict oldest files first
        fileInfos.sort { $0.date < $1.date }
        for info in fileInfos {
            try? fm.removeItem(at: info.url)
            totalSize -= info.size
            if totalSize <= maxDiskSize { break }
        }
    }
}

// MARK: - Cache Entry

final class CacheEntry: NSObject, Codable {
    let data: Data
    let timestamp: Date

    init(data: Data, timestamp: Date) {
        self.data = data
        self.timestamp = timestamp
    }

    func decode<T: Decodable>(as type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Cache Result

struct CachedResult<T: Sendable>: Sendable {
    let value: T
    let isStale: Bool
}

// MARK: - Cache Keys

enum CacheKey {
    static func sections(serverId: String) -> String {
        "sections_\(serverId)"
    }
    static func artists(serverId: String, sectionId: String) -> String {
        "artists_\(serverId)_\(sectionId)"
    }
    static func albums(serverId: String, sectionId: String) -> String {
        "albums_\(serverId)_\(sectionId)"
    }
    static func tracks(serverId: String, sectionId: String) -> String {
        "tracks_\(serverId)_\(sectionId)"
    }
    static func children(ratingKey: String) -> String {
        "children_\(ratingKey)"
    }
    static func metadata(ratingKey: String) -> String {
        "metadata_\(ratingKey)"
    }
    static func playlists(serverId: String) -> String {
        "playlists_\(serverId)"
    }
    static func playlistItems(playlistKey: String) -> String {
        "playlist_items_\(playlistKey)"
    }
    static func search(query: String, sectionId: String?) -> String {
        "search_\(query)_\(sectionId ?? "all")"
    }
    static func lyrics(title: String, artist: String) -> String {
        "lyrics_\(artist)_\(title)"
    }
}

// MARK: - String SHA256

import CryptoKit

private extension String {
    var sha256Hash: String {
        let hash = SHA256.hash(data: Data(utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
