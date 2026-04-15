import SwiftUI
import CryptoKit
import ImageIO

/// Two-tier image cache: NSCache (memory) + disk (Caches directory).
/// Images are keyed by URL string, hashed to SHA256 for disk filenames.
actor ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
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
        let memoryKey = memoryCacheKey(for: key, targetPixelSize: targetPixelSize)

        // 1. Memory
        if let cached = memoryCache.object(forKey: memoryKey as NSString) {
#if DEBUG
            debugStats.memoryHits += 1
            debugStats.recordLookupLatency(since: start)
#endif
            return cached
        }

        // 2. Disk
        if let diskImage = loadFromDisk(key: key, targetPixelSize: targetPixelSize) {
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
        let requestKey = "\(key)|\(targetPixelSize ?? 0)"
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
            await download(url: url, key: key, memoryKey: memoryKey, targetPixelSize: targetPixelSize)
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

    private func download(url: URL, key: String, memoryKey: String, targetPixelSize: Int?) async -> UIImage? {
        let startGeneration = generation
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            // If cache was cleared during download, don't save stale data
            guard generation == startGeneration else { return nil }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = decodeImage(from: data, targetPixelSize: targetPixelSize) else { return nil }

            memoryCache.setObject(image, forKey: memoryKey as NSString, cost: image.decodedCost)
            saveToDisk(data: data, key: key)
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

    private func loadFromDisk(key: String, targetPixelSize: Int?) -> UIImage? {
        let fileURL = diskURL.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        // Touch the file to update access time for LRU eviction
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
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
