import SwiftUI
import CryptoKit
import ImageIO

/// Two-tier image cache: NSCache (memory) + disk (Caches directory).
/// Images are keyed by URL string, hashed to SHA256 for disk filenames.
actor ImageCache {
    static let shared = ImageCache()

    // NSCache is documented thread-safe, so reads/writes from nonisolated contexts are fine.
    nonisolated(unsafe) private let memoryCache = NSCache<NSString, UIImage>()
    private let diskURL: URL
    private let maxDiskBytes: Int = 500 * 1024 * 1024 // 500 MB
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    /// Incremented on clearAll to invalidate in-progress downloads.
    private var generation: Int = 0
#if DEBUG
    private var debugStats = DebugStats()
#endif

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskURL = caches.appendingPathComponent("TrommeImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    // MARK: - Public API

    func image(for url: URL, targetPixelSize: Int? = nil) async -> UIImage? {
#if DEBUG
        let start = ContinuousClock.now
#endif
        let key = cacheKey(for: url)
        // Disk key strips width/height so one stored copy per artwork serves every size.
        let diskKey = diskCacheKey(for: url)
        let memoryKey = memoryCacheKey(for: key, targetPixelSize: targetPixelSize)

        // 1. Memory
        if let cached = memoryCache.object(forKey: memoryKey as NSString) {
#if DEBUG
            debugStats.memoryHits += 1
            debugStats.recordLookupLatency(since: start)
#endif
            return cached
        }

        // 2. Disk (size-independent key). Only serve the stored file if its pixels
        // cover the requested size — an undersized copy falls through to a
        // re-download so large surfaces (Now Playing, album headers) don't get
        // a small image upscaled. The undersized file remains as an offline fallback.
        if let diskImage = loadFromDisk(key: diskKey, targetPixelSize: targetPixelSize, minimumPixelSize: targetPixelSize) {
            memoryCache.setObject(diskImage, forKey: memoryKey as NSString, cost: diskImage.decodedCost)
#if DEBUG
            debugStats.diskHits += 1
            debugStats.recordLookupLatency(since: start)
#endif
            return diskImage
        }
#if DEBUG
        debugStats.misses += 1
#endif

        // 3. Coalesce in-flight requests for the same URL
        let requestKey = "\(diskKey)|\(targetPixelSize ?? 0)"
        if let existing = inFlightRequests[requestKey] {
#if DEBUG
            debugStats.coalescedHits += 1
            let value = await existing.value
            debugStats.recordLookupLatency(since: start)
            return value
#else
            return await existing.value
#endif
        }

#if DEBUG
        debugStats.networkRequests += 1
#endif
        let task = Task<UIImage?, Never> {
            if let downloaded = await self.download(url: url, diskKey: diskKey, memoryKey: memoryKey, targetPixelSize: targetPixelSize) {
                return downloaded
            }
            // Offline or failed fetch: serve an undersized disk copy rather than nothing.
            if let fallback = self.loadFromDisk(key: diskKey, targetPixelSize: targetPixelSize) {
                self.memoryCache.setObject(fallback, forKey: memoryKey as NSString, cost: fallback.decodedCost)
                return fallback
            }
            return nil
        }
        inFlightRequests[requestKey] = task
        let result = await task.value
        inFlightRequests[requestKey] = nil
#if DEBUG
        debugStats.recordLookupLatency(since: start)
#endif
        return result
    }

    func prefetch(urls: [URL], targetPixelSize: Int? = nil, maxConcurrent: Int = 6) async {
        // Process in batches to avoid overwhelming the network
        for batch in stride(from: 0, to: urls.count, by: maxConcurrent) {
            let batchURLs = urls[batch..<min(batch + maxConcurrent, urls.count)]
            await withTaskGroup(of: Void.self) { group in
                for url in batchURLs {
                    group.addTask {
                        _ = await self.image(for: url, targetPixelSize: targetPixelSize)
                    }
                }
            }
        }
    }

    /// Synchronously returns an in-memory cached image if present. Used by views that need
    /// to render cached art on the very first frame without waiting for an actor hop.
    nonisolated func memoryCachedImage(for url: URL, targetPixelSize: Int? = nil) -> UIImage? {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let baseKey = hash.map { String(format: "%02x", $0) }.joined()
        let bucket = (targetPixelSize ?? 0) / 32 * 32
        let memoryKey = "\(baseKey)_\(bucket)" as NSString
        return memoryCache.object(forKey: memoryKey)
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
#if DEBUG
        debugStats.memoryClears += 1
#endif
    }

    func clearAll() {
        generation += 1
        memoryCache.removeAllObjects()
        // Cancel all in-flight downloads so they don't write back to the cleared cache
        for (key, task) in inFlightRequests {
            task.cancel()
            inFlightRequests[key] = nil
        }
        try? FileManager.default.removeItem(at: diskURL)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
#if DEBUG
        debugStats.memoryClears += 1
#endif
    }

    // MARK: - Private

    private func download(url: URL, diskKey: String, memoryKey: String, targetPixelSize: Int?) async -> UIImage? {
        let startGeneration = generation
        // Fetch at least 512px so small row requests still store a reasonably sharp shared
        // copy. Larger surfaces re-fetch at their own size when the stored file is too small.
        // Memory is still decoded at the originally requested size.
        let fetchURL = upgradedDownloadURL(from: url, minimumSize: 512)
        do {
            let (data, response) = try await URLSession.shared.data(from: fetchURL)
            // If cache was cleared during download, don't save stale data
            guard generation == startGeneration else { return nil }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = decodeImage(from: data, targetPixelSize: targetPixelSize) else { return nil }

            memoryCache.setObject(image, forKey: memoryKey as NSString, cost: image.decodedCost)
            saveToDisk(data: data, key: diskKey)
#if DEBUG
            debugStats.networkSuccesses += 1
#endif
            return image
        } catch {
#if DEBUG
            debugStats.networkFailures += 1
#endif
            return nil
        }
    }

    /// Loads and decodes a disk-cached image. When `minimumPixelSize` is set, returns nil
    /// if the stored file's pixel dimensions are smaller — signaling the caller to re-fetch
    /// a larger copy instead of upscaling.
    private func loadFromDisk(key: String, targetPixelSize: Int?, minimumPixelSize: Int? = nil) -> UIImage? {
        let fileURL = diskURL.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        // Touch the file to update access time for LRU eviction
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        if let minimumPixelSize, minimumPixelSize > 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard max(width, height) >= minimumPixelSize else { return nil }
        }
        return decodeImage(from: source, targetPixelSize: targetPixelSize)
    }

    private func saveToDisk(data: Data, key: String) {
        let fileURL = diskURL.appendingPathComponent(key)
        try? data.write(to: fileURL, options: .atomic)
        trimDiskCacheIfNeeded()
    }

    private func trimDiskCacheIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var totalSize = 0
        var fileInfos: [(url: URL, date: Date, size: Int)] = []

        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else { continue }
            totalSize += size
            fileInfos.append((file, date, size))
        }

        guard totalSize > maxDiskBytes else { return }

        // Evict oldest files first
        fileInfos.sort { $0.date < $1.date }
        for info in fileInfos {
            try? fm.removeItem(at: info.url)
            totalSize -= info.size
            if totalSize <= maxDiskBytes / 2 { break }
        }
    }

    private func cacheKey(for url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a URL with `width`/`height` params raised to at least `minimumSize`.
    /// Used so every disk-cached file is high enough quality to serve Now Playing offline.
    private func upgradedDownloadURL(from url: URL, minimumSize: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return url }
        let currentW = items.first(where: { $0.name == "width" }).flatMap { Int($0.value ?? "") } ?? 0
        let currentH = items.first(where: { $0.name == "height" }).flatMap { Int($0.value ?? "") } ?? 0
        guard currentW < minimumSize || currentH < minimumSize else { return url }
        components.queryItems = items.map { item in
            if item.name == "width" { return URLQueryItem(name: "width", value: "\(max(currentW, minimumSize))") }
            if item.name == "height" { return URLQueryItem(name: "height", value: "\(max(currentH, minimumSize))") }
            return item
        }
        return components.url ?? url
    }

    /// Cache key for disk storage. Strips `width`/`height` so one file serves every
    /// display size, and strips the host+port so artwork cached on a local URI is still
    /// found when the server reprobe switches to a remote URI (or vice versa).
    /// The thumb identity is preserved via the `url` query param and `X-Plex-Token`.
    private func diskCacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return cacheKey(for: url)
        }
        var changed = false
        if let items = components.queryItems,
           items.contains(where: { $0.name == "width" || $0.name == "height" }) {
            components.queryItems = items.filter { $0.name != "width" && $0.name != "height" }
            changed = true
        }
        // Drop the scheme/host/port so the key is stable across server URI changes
        // (e.g. local LAN ↔ remote reprobe). The `url` query param uniquely identifies
        // the artwork regardless of which server base URL is currently active.
        if components.host != nil {
            components.scheme = nil
            components.host = nil
            components.port = nil
            changed = true
        }
        guard changed else { return cacheKey(for: url) }
        let normalized = components.url ?? url
        let hash = SHA256.hash(data: Data(normalized.absoluteString.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func memoryCacheKey(for baseKey: String, targetPixelSize: Int?) -> String {
        let bucket = (targetPixelSize ?? 0) / 32 * 32
        return "\(baseKey)_\(bucket)"
    }

    private func decodeImage(from data: Data, targetPixelSize: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decodeImage(from: source, targetPixelSize: targetPixelSize)
    }

    private func decodeImage(from source: CGImageSource, targetPixelSize: Int?) -> UIImage? {
        let options: CFDictionary
        if let targetPixelSize, targetPixelSize > 0 {
            options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return UIImage(cgImage: image)
        } else {
            options = [
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
            return UIImage(cgImage: image)
        }
    }
}

#if DEBUG
extension ImageCache {
    struct DebugStats: Sendable {
        var memoryHits: Int = 0
        var diskHits: Int = 0
        var misses: Int = 0
        var coalescedHits: Int = 0
        var networkRequests: Int = 0
        var networkSuccesses: Int = 0
        var networkFailures: Int = 0
        var memoryClears: Int = 0
        var totalLookups: Int = 0
        var totalLookupDurationMs: Double = 0

        var cacheHits: Int { memoryHits + diskHits }
        var memoryHitRate: Double { percentage(memoryHits, outOf: totalLookups) }
        var diskHitRate: Double { percentage(diskHits, outOf: totalLookups) }
        var missRate: Double { percentage(misses, outOf: totalLookups) }
        var averageLookupMs: Double {
            guard totalLookups > 0 else { return 0 }
            return totalLookupDurationMs / Double(totalLookups)
        }

        mutating func recordLookupLatency(since start: ContinuousClock.Instant) {
            let ms = start.duration(to: ContinuousClock.now).milliseconds
            totalLookups += 1
            totalLookupDurationMs += ms
        }

        private func percentage(_ value: Int, outOf total: Int) -> Double {
            guard total > 0 else { return 0 }
            return (Double(value) / Double(total)) * 100
        }
    }

    func debugStatsSnapshot() -> DebugStats {
        debugStats
    }

    func resetDebugStats() {
        debugStats = DebugStats()
    }

    func debugStatsSummary() -> String {
        let stats = debugStats
        return """
        ImageCache Stats
        - lookups: \(stats.totalLookups)
        - memory hits: \(stats.memoryHits) (\(stats.memoryHitRate.formatted(.number.precision(.fractionLength(1))))%)
        - disk hits: \(stats.diskHits) (\(stats.diskHitRate.formatted(.number.precision(.fractionLength(1))))%)
        - misses: \(stats.misses) (\(stats.missRate.formatted(.number.precision(.fractionLength(1))))%)
        - coalesced waits: \(stats.coalescedHits)
        - network requests: \(stats.networkRequests)
        - network successes: \(stats.networkSuccesses)
        - network failures: \(stats.networkFailures)
        - avg lookup latency: \(stats.averageLookupMs.formatted(.number.precision(.fractionLength(1)))) ms
        """
    }

    func debugPrintStats() {
        print(debugStatsSummary())
    }

    nonisolated static func debugMemoryKey(for url: URL, targetPixelSize: Int?) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let base = hash.map { String(format: "%02x", $0) }.joined()
        let bucket = (targetPixelSize ?? 0) / 32 * 32
        return "\(base)_\(bucket)"
    }
}
#endif

#if DEBUG
private extension Duration {
    var milliseconds: Double {
        let components = self.components
        let secondsMs = Double(components.seconds) * 1_000
        let attosecondsMs = Double(components.attoseconds) / 1_000_000_000_000_000
        return secondsMs + attosecondsMs
    }
}
#endif

private extension UIImage {
    var decodedCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
