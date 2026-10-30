import Foundation
import CryptoKit

actor ExternalContentCache {
    static let shared = ExternalContentCache()

    nonisolated(unsafe) private let memoryCache = NSCache<NSString, CacheEntry>()
    private let diskURL: URL
    private let defaultTTL: TimeInterval = 1800 // 30 minutes for memory freshness
    private let diskTTL: TimeInterval = 86400 // 24 hours for disk staleness
    private let maxDiskSize: Int = 32 * 1024 * 1024 // 32 MB

    private var inFlightFetches: [String: Any] = [:]
    private var generation: Int = 0
    private var currentDiskBytes: Int = 0

    private init() {
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: caches.appendingPathComponent("TrommeLibraryCache", isDirectory: true))
        }
        try? fm.removeItem(at: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrommeLibraryCache", isDirectory: true))
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrommeExternalContentCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        diskURL = dir
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
        currentDiskBytes = Self.scanDiskBytes(at: diskURL)
    }

    private static func scanDiskBytes(at url: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: - Public API

    nonisolated func memoryCached<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> T? {
        guard let entry = memoryCache.object(forKey: key as NSString) else { return nil }
        return entry.decode(as: type)
    }

    func get<T: Codable & Sendable>(_ type: T.Type, forKey key: String) -> CachedResult<T>? {
        get(type, forKey: key, diskTTL: diskTTL)
    }

    func get<T: Codable & Sendable>(_ type: T.Type, forKey key: String, diskTTL: TimeInterval) -> CachedResult<T>? {
        if let entry = memoryCache.object(forKey: key as NSString),
           let value = entry.decode(as: T.self) {
            let fresh = Date().timeIntervalSince(entry.timestamp) < defaultTTL
            return CachedResult(value: value, isStale: !fresh)
        }

        if let entry = loadFromDisk(key: key),
           let value = entry.decode(as: T.self) {
            memoryCache.setObject(entry, forKey: key as NSString, cost: entry.data.count)
            let stale = Date().timeIntervalSince(entry.timestamp) > diskTTL
            return CachedResult(value: value, isStale: stale)
        }

        return nil
    }

    func set<T: Codable & Sendable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let entry = CacheEntry(data: data, timestamp: Date())
        memoryCache.setObject(entry, forKey: key as NSString, cost: data.count)
        saveToDisk(entry: entry, key: key)
    }

    func remove(forKey key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        let fileURL = diskURL.appendingPathComponent(key.sha256Hash)
        let removedSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        try? FileManager.default.removeItem(at: fileURL)
        currentDiskBytes -= removedSize ?? 0
    }

    func clearAll() {
        generation += 1
        memoryCache.removeAllObjects()
        inFlightFetches.removeAll()
        try? FileManager.default.removeItem(at: diskURL)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        currentDiskBytes = 0
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
    }

// MARK: - Cached Fetch (single entry point)

    func cachedFetch<T: Codable & Sendable>(
        _ type: T.Type = T.self,
        forKey key: String,
        policy: CachePolicy = .detail,
        fetch: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        if let cached = get(type, forKey: key, policy: policy) {
            if !cached.isStale { return cached.value }
            Task { try? await coalescedFetch(fetch, forKey: key) }
            return cached.value
        }
        return try await coalescedFetch(fetch, forKey: key)
    }

    // MARK: - In-Flight Deduplication

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
        if let entry = memoryCache.object(forKey: key as NSString),
           let value = entry.decode(as: T.self) {
            let fresh = Date().timeIntervalSince(entry.timestamp) < policy.memoryTTL
            return CachedResult(value: value, isStale: !fresh)
        }

        if let entry = loadFromDisk(key: key),
           let value = entry.decode(as: T.self) {
            memoryCache.setObject(entry, forKey: key as NSString, cost: entry.data.count)
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
        let previousSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        try? data.write(to: fileURL, options: .atomic)
        currentDiskBytes += data.count - (previousSize ?? 0)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard currentDiskBytes > maxDiskSize else { return }
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

        fileInfos.sort { $0.date < $1.date }
        for info in fileInfos {
            guard totalSize > maxDiskSize else { break }
            try? fm.removeItem(at: info.url)
            totalSize -= info.size
        }
        currentDiskBytes = totalSize
    }
}

// MARK: - String SHA256

private extension String {
    var sha256Hash: String {
        let hash = SHA256.hash(data: Data(utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
