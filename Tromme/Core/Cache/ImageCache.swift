import SwiftUI
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Two-tier image cache: NSCache (memory) + disk (Caches directory).
/// Images are keyed by URL string, hashed to SHA256 for disk filenames.
///
/// The actor only guards bookkeeping (in-flight requests, disk byte count, generation).
/// Disk reads, decoding, and HEIC encoding run off the actor in `@concurrent` helpers,
/// so many rows can decode in parallel instead of queueing behind one another.
actor ImageCache {
    static let shared = ImageCache()

    // NSCache is documented thread-safe, so reads/writes from nonisolated contexts are fine.
    nonisolated(unsafe) private let memoryCache = NSCache<NSString, UIImage>()
    private let diskURL: URL
    private let maxDiskBytes: Int = 500 * 1024 * 1024 // 500 MB
    // Tracked incrementally so routine saves don't need a full directory scan;
    // only refreshed by an authoritative re-scan when trimDiskCacheIfNeeded() runs.
    private var currentDiskBytes: Int = 0
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    // Disk files whose modification date has already been bumped this session. LRU
    // eviction only needs a rough recency signal, so each file is touched at most once
    // instead of paying a metadata write on every read.
    private var touchedDiskKeys: Set<String> = []
    // Short timeout so unreachable servers don't block artwork for tens of seconds.
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()
    /// Incremented on clearAll to invalidate in-progress downloads.
    private var generation: Int = 0
#if DEBUG
    private var debugStats = DebugStats()
#endif

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskURL = caches.appendingPathComponent("TrommeImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        // Cost is the real limit; the count is only a backstop so long lists of small
        // row thumbnails aren't evicted while well under the byte budget.
        memoryCache.countLimit = 1000
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
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

        // 2. Coalesce in-flight requests for the same artwork and size, so a disk decode
        // or download happens once no matter how many rows ask for it at the same time.
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

        let task = Task<UIImage?, Never> {
            await self.resolve(url: url, diskKey: diskKey, memoryKey: memoryKey, targetPixelSize: targetPixelSize)
        }
        inFlightRequests[requestKey] = task
        let result = await task.value
        inFlightRequests[requestKey] = nil
#if DEBUG
        debugStats.recordLookupLatency(since: start)
#endif
        return result
    }

    /// Returns any cached image for the URL without attempting a network download.
    /// Checks memory first, then disk without a minimum-size requirement. Used for
    /// a fast pre-population step so views show something immediately on slow networks.
    func anyCachedImage(for url: URL, targetPixelSize: Int?) async -> UIImage? {
        let memKey = memoryCacheKey(for: cacheKey(for: url), targetPixelSize: targetPixelSize)
        if let mem = memoryCache.object(forKey: memKey as NSString) { return mem }
        let diskKey = diskCacheKey(for: url)
        guard let result = await Self.loadFromDisk(
            at: diskURL.appendingPathComponent(diskKey),
            targetPixelSize: targetPixelSize,
            requireFullSize: false,
            touch: touchedDiskKeys.insert(diskKey).inserted
        ) else { return nil }
        // A copy that already covers the requested size is the final image — cache it so
        // the caller's follow-up image(for:) is a memory hit instead of a second decode.
        if result.isFullSize {
            memoryCache.setObject(result.image, forKey: memKey as NSString, cost: result.image.decodedCost)
        }
        return result.image
    }

    func prefetch(urls: [URL], targetPixelSize: Int? = nil, maxConcurrent: Int = 6) async {
        // Skip anything already decoded and sitting in the memory cache. Several call
        // sites (warmCache, repeated screen visits) prefetch overlapping artist/album
        // sets, and re-decoding them is wasted work. Also drop duplicates — tracks on
        // the same album share artwork.
        var seen: Set<String> = []
        let pending = urls.filter {
            let key = memoryCacheKey(for: cacheKey(for: $0), targetPixelSize: targetPixelSize)
            return memoryCache.object(forKey: key as NSString) == nil && seen.insert(key).inserted
        }
        guard !pending.isEmpty else { return }
        // Rolling window: start the next fetch as soon as any one finishes rather than
        // waiting on the slowest of a fixed batch. Utility priority keeps prefetch behind
        // on-screen rows; a row that needs a prefetching image awaits the same coalesced
        // task, which escalates its priority.
        var remaining = pending[...]
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(maxConcurrent, 1) {
                guard let url = remaining.popFirst() else { break }
                group.addTask(priority: .utility) {
                    _ = await self.image(for: url, targetPixelSize: targetPixelSize)
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let url = remaining.popFirst() else { continue }
                group.addTask(priority: .utility) {
                    _ = await self.image(for: url, targetPixelSize: targetPixelSize)
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
        currentDiskBytes = 0
        touchedDiskKeys.removeAll()
#if DEBUG
        debugStats.memoryClears += 1
#endif
    }

    // MARK: - Private

    /// Body of a coalesced lookup: disk, then network, then an undersized disk fallback.
    private func resolve(url: URL, diskKey: String, memoryKey: String, targetPixelSize: Int?) async -> UIImage? {
        let fileURL = diskURL.appendingPathComponent(diskKey)

        // Disk (size-independent key). Only serve the stored file if its pixels cover
        // the requested size — an undersized copy falls through to a re-download so
        // large surfaces (Now Playing, album headers) don't get a small image upscaled.
        // The undersized file remains as an offline fallback.
        if let disk = await Self.loadFromDisk(
            at: fileURL,
            targetPixelSize: targetPixelSize,
            requireFullSize: true,
            touch: touchedDiskKeys.insert(diskKey).inserted
        ) {
            memoryCache.setObject(disk.image, forKey: memoryKey as NSString, cost: disk.image.decodedCost)
#if DEBUG
            debugStats.diskHits += 1
#endif
            return disk.image
        }
#if DEBUG
        debugStats.misses += 1
#endif

        // Online: fetch a properly sized copy. Offline skips straight to the fallback.
        if NetworkStatus.shared.isConnected {
#if DEBUG
            debugStats.networkRequests += 1
#endif
            if let downloaded = await download(url: url, diskKey: diskKey, memoryKey: memoryKey, targetPixelSize: targetPixelSize) {
                return downloaded
            }
        }

        // Offline or failed fetch: serve an undersized disk copy rather than nothing.
        if let fallback = await Self.loadFromDisk(at: fileURL, targetPixelSize: targetPixelSize, requireFullSize: false, touch: false) {
            memoryCache.setObject(fallback.image, forKey: memoryKey as NSString, cost: fallback.image.decodedCost)
            return fallback.image
        }
        return nil
    }

    private func download(url: URL, diskKey: String, memoryKey: String, targetPixelSize: Int?) async -> UIImage? {
        let startGeneration = generation
        // Fetch at least 512px so small row requests still store a reasonably sharp shared
        // copy. Larger surfaces re-fetch at their own size when the stored file is too small.
        // Memory is still decoded at the originally requested size.
        let fetchURL = upgradedDownloadURL(from: url, minimumSize: 512)
        guard let (data, image) = await Self.fetchAndDecode(fetchURL, targetPixelSize: targetPixelSize) else {
#if DEBUG
            debugStats.networkFailures += 1
#endif
            return nil
        }
        // If cache was cleared during download, don't save stale data
        guard generation == startGeneration else { return nil }

        memoryCache.setObject(image, forKey: memoryKey as NSString, cost: image.decodedCost)
        // Hand the image back now; the HEIC re-encode and disk write happen in the
        // background so they never delay this or any other artwork request.
        let fileURL = diskURL.appendingPathComponent(diskKey)
        Task(priority: .background) {
            let bytesDelta = await Self.encodeAndWrite(data, to: fileURL)
            self.didWriteToDisk(fileURL: fileURL, bytesDelta: bytesDelta, generation: startGeneration)
        }
#if DEBUG
        debugStats.networkSuccesses += 1
#endif
        return image
    }

    private func didWriteToDisk(fileURL: URL, bytesDelta: Int, generation writeGeneration: Int) {
        // The cache was cleared while this file was being encoded — drop it.
        guard writeGeneration == generation else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        currentDiskBytes += bytesDelta
        trimDiskCacheIfNeeded()
    }

    /// Cheap check against the incrementally-tracked byte total; only falls back to a
    /// full directory scan (needed to find the oldest files) once actually over the cap,
    /// instead of scanning every file on every single save.
    private func trimDiskCacheIfNeeded() {
        guard currentDiskBytes > maxDiskBytes else { return }
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

        // Evict oldest files first
        fileInfos.sort { $0.date < $1.date }
        for info in fileInfos {
            guard totalSize > maxDiskBytes / 2 else { break }
            try? fm.removeItem(at: info.url)
            totalSize -= info.size
        }
        currentDiskBytes = totalSize
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

    // MARK: - Off-actor I/O and decoding

    private struct DiskImage: Sendable {
        let image: UIImage
        /// Whether the stored file's pixels cover the requested size.
        let isFullSize: Bool
    }

    /// Loads and decodes a disk-cached image. With `requireFullSize`, returns nil before
    /// decoding if the stored file is smaller than `targetPixelSize` — signaling the
    /// caller to re-fetch a larger copy instead of upscaling.
    @concurrent
    private static func loadFromDisk(at fileURL: URL, targetPixelSize: Int?, requireFullSize: Bool, touch: Bool) async -> DiskImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        var isFullSize = true
        if let targetPixelSize, targetPixelSize > 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            isFullSize = max(width, height) >= targetPixelSize
        }
        if requireFullSize && !isFullSize { return nil }
        guard let image = decodeImage(from: source, targetPixelSize: targetPixelSize) else { return nil }
        if touch {
            // Bump the modification date for LRU eviction
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        }
        return DiskImage(image: image, isFullSize: isFullSize)
    }

    @concurrent
    private static func fetchAndDecode(_ url: URL, targetPixelSize: Int?) async -> (Data, UIImage)? {
        guard let (data, response) = try? await downloadSession.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let image = decodeImage(from: data, targetPixelSize: targetPixelSize) else { return nil }
        return (data, image)
    }

    /// Writes downloaded bytes to disk and returns the change in on-disk size.
    /// Re-encodes to HEIC first — roughly half the file size of the JPEG Plex sends at
    /// the same visual quality, and it's hardware-accelerated on every device this app
    /// targets. Falls back to the original bytes if HEIC encoding is unavailable (e.g.
    /// running on a Simulator without the encoder).
    @concurrent
    private static func encodeAndWrite(_ data: Data, to fileURL: URL) async -> Int {
        let encoded = heicData(from: data) ?? data
        let previousSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard (try? encoded.write(to: fileURL, options: .atomic)) != nil else { return 0 }
        return encoded.count - previousSize
    }

    /// Re-encodes image bytes as HEIC at full resolution. Returns nil if the source can't
    /// be decoded or the device has no HEIC encoder.
    private static func heicData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    private static func decodeImage(from data: Data, targetPixelSize: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decodeImage(from: source, targetPixelSize: targetPixelSize)
    }

    private static func decodeImage(from source: CGImageSource, targetPixelSize: Int?) -> UIImage? {
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
