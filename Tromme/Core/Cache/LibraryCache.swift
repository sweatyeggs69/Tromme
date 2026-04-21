import Foundation

/// Cache for Plex library API responses. Uses NSCache for memory and
/// JSON files on disk for persistence across launches.
///
/// Strategy: return cached data immediately, then refresh in background.
/// Views call `get()` for cache-first, or `fetch()` to force refresh.
///
/// In-flight deduplication: concurrent requests for the same key share
/// one network fetch via `withFetch(_:forKey:)`.
actor LibraryCache {
    static let shared = LibraryCache()

    private let memoryCache = NSCache<NSString, CacheEntry>()
    private let diskURL: URL
    private let defaultTTL: TimeInterval = 1800 // 30 minutes for memory freshness
    private let diskTTL: TimeInterval = 86400 // 24 hours for disk staleness
    private let maxDiskSize: Int = 50 * 1024 * 1024 // 50 MB

    /// Tracks in-flight fetch tasks by cache key so concurrent callers
    /// share one network request instead of firing duplicates.
    private var inFlightFetches: [String: Any] = [:]
    /// Incremented on clearAll to invalidate in-progress fetches.
    private var generation: Int = 0

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
        generation += 1
        memoryCache.removeAllObjects()
        inFlightFetches.removeAll()
        try? FileManager.default.removeItem(at: diskURL)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
    }

    /// Clear only memory cache (keeps disk).
    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    // MARK: - Cached Fetch (single entry point)

    /// The single entry point for all cache-first data access. Encapsulates
    /// the entire stale-while-revalidate + request coalescing pattern:
    ///
    /// 1. If cached and fresh → return immediately
    /// 2. If cached but stale → return immediately, background refresh
    /// 3. If not cached → fetch, cache, and return
    ///
    /// Concurrent callers for the same key share one in-flight request.
    func cachedFetch<T: Codable & Sendable>(
        _ type: T.Type = T.self,
        forKey key: String,
        policy: CachePolicy = .detail,
        fetch: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        // Check cache with policy-specific TTLs
        if let cached = get(type, forKey: key, policy: policy) {
            if !cached.isStale { return cached.value }
            // Stale — return cached value, refresh in background
            Task { try? await coalescedFetch(fetch, forKey: key) }
            return cached.value
        }
        // No cache — fetch synchronously
        return try await coalescedFetch(fetch, forKey: key)
    }

    // MARK: - In-Flight Deduplication

    /// Execute a fetch closure, deduplicating concurrent requests for the same key.
    /// If another caller is already fetching for this key, this call joins that
    /// in-flight request rather than starting a duplicate network call.
    func withFetch<T: Codable & Sendable>(
        _ fetch: @Sendable @escaping () async throws -> T,
        forKey key: String
    ) async throws -> T {
        try await coalescedFetch(fetch, forKey: key)
    }

    private func coalescedFetch<T: Codable & Sendable>(
        _ fetch: @Sendable @escaping () async throws -> T,
        forKey key: String
    ) async throws -> T {
        // If there's already an in-flight fetch for this key, join it
        if let existing = inFlightFetches[key] as? Task<T, Error> {
            return try await existing.value
        }

        let startGeneration = generation
        let task = Task<T, Error> {
            try await fetch()
        }
        inFlightFetches[key] = task

        do {
            let result = try await task.value
            inFlightFetches[key] = nil
            // Only write to cache if it wasn't cleared during the fetch
            if generation == startGeneration {
                set(result, forKey: key)
            }
            return result
        } catch {
            inFlightFetches[key] = nil
            throw error
        }
    }

    // MARK: - Policy-Aware Get

    private func get<T: Codable & Sendable>(_ type: T.Type, forKey key: String, policy: CachePolicy) -> CachedResult<T>? {
        // 1. Memory cache
        if let entry = memoryCache.object(forKey: key as NSString),
           let value = entry.decode(as: T.self) {
            let fresh = Date().timeIntervalSince(entry.timestamp) < policy.memoryTTL
            return CachedResult(value: value, isStale: !fresh)
        }

        // 2. Disk cache
        if let entry = loadFromDisk(key: key),
           let value = entry.decode(as: T.self) {
            memoryCache.setObject(entry, forKey: key as NSString)
            let stale = Date().timeIntervalSince(entry.timestamp) > policy.diskTTL
            return CachedResult(value: value, isStale: stale)
        }

        return nil
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

// MARK: - Cache Policy

/// Per-data-type freshness windows. Different data changes at different rates,
/// so a one-size-fits-all TTL leaves some data stale and over-fetches others.
enum CachePolicy: Sendable {
    /// Large, rarely-changing lists (all artists, all albums, all tracks).
    /// Memory: 4 hours, Disk: 30 days.
    case library
    /// Detail pages, children, top tracks — moderate change frequency.
    /// Memory: 2 hours, Disk: 7 days.
    case detail
    /// Album info/summary payloads for album detail.
    /// Memory: 2 hours, Disk: 24 hours.
    case albumInfo
    /// Playlists, favorites — user-editable, changes more often.
    /// Memory: 1 hour, Disk: 3 days.
    case userContent
    /// Search results — short-lived, mostly just deduplication.
    /// Memory: 10 min, Disk: 4 hours.
    case search
    /// Album styles — very stable metadata.
    /// Memory: 4 hours, Disk: 30 days.
    case styles

    var memoryTTL: TimeInterval {
        switch self {
        case .library:     return 14400     // 4 hours
        case .detail:      return 7200      // 2 hours
        case .albumInfo:   return 7200      // 2 hours
        case .userContent: return 3600      // 1 hour
        case .search:      return 600       // 10 min
        case .styles:      return 14400     // 4 hours
        }
    }

    var diskTTL: TimeInterval {
        switch self {
        case .library:     return 2_592_000 // 30 days
        case .detail:      return 604_800   // 7 days
        case .albumInfo:   return 86_400    // 24 hours
        case .userContent: return 259_200   // 3 days
        case .search:      return 14400     // 4 hours
        case .styles:      return 2_592_000 // 30 days
        }
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
    static func albumStyles(serverId: String, sectionId: String) -> String {
        "album_styles_\(serverId)_\(sectionId)"
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
    static func topTracks(artistRatingKey: String) -> String {
        "top_tracks_\(artistRatingKey)"
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
