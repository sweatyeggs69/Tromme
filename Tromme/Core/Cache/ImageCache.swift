import SwiftUI
import CryptoKit
import ImageIO

actor ImageCache {
    static let shared = ImageCache()

    nonisolated(unsafe) private let memoryCache = NSCache<NSString, UIImage>()
    private let diskURL: URL
    private let maxDiskBytes: Int = 400 * 1024 * 1024 // 400 MB
    private var currentDiskBytes: Int = 0
    private var inFlightRequests: [String: Task<UIImage?, Never>] = [:]
    private var touchedDiskKeys: Set<String> = []
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()
    private var generation: Int = 0
#if DEBUG
    private var debugStats = DebugStats()
#endif

    private init() {
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: caches.appendingPathComponent("TrommeImageCache", isDirectory: true))
        }
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrommeImageStore", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        diskURL = dir
        memoryCache.countLimit = 1000
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        currentDiskBytes = Self.scanDiskBytes(at: diskURL)
        Task(priority: .background) { await self.trimDiskCacheIfNeeded() }
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
        let diskKey = diskCacheKey(for: url)
        let memoryKey = memoryCacheKey(for: key, targetPixelSize: targetPixelSize)

        if let cached = memoryCache.object(forKey: memoryKey as NSString) {
#if DEBUG
            debugStats.memoryHits += 1
            debugStats.recordLookupLatency(since: start)
#endif
            return cached
        }

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
        if result.isFullSize {
            memoryCache.setObject(result.image, forKey: memKey as NSString, cost: result.image.decodedCost)
        }
        return result.image
    }

    func prefetch(urls: [URL], targetPixelSize: Int? = nil, maxConcurrent: Int = 6) async {
        var seen: Set<String> = []
        let pending = urls.filter {
            let key = memoryCacheKey(for: cacheKey(for: $0), targetPixelSize: targetPixelSize)
            return memoryCache.object(forKey: key as NSString) == nil && seen.insert(key).inserted
        }
        guard !pending.isEmpty else { return }
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

    func storeToDisk(urls: [URL], pixelSize: Int, maxConcurrent: Int = 4) async {
        var seen = Set<String>()
        var pending: [(url: URL, diskKey: String)] = []
        for url in urls {
            let diskKey = diskCacheKey(for: url)
            guard seen.insert(diskKey).inserted else { continue }
            let fileURL = diskURL.appendingPathComponent(diskKey)
            if await Self.storedPixelSize(at: fileURL) >= pixelSize { continue }
            pending.append((upgradedDownloadURL(from: url, minimumSize: pixelSize), diskKey))
        }
        guard !pending.isEmpty else { return }

        var remaining = pending[...]
        await withTaskGroup(of: Void.self) { group in
            func start() {
                guard !Task.isCancelled, NetworkStatus.shared.isConnected,
                      let next = remaining.popFirst() else { return }
                group.addTask(priority: .utility) {
                    await self.downloadToDisk(url: next.url, diskKey: next.diskKey)
                }
            }
            for _ in 0..<max(maxConcurrent, 1) { start() }
            while await group.next() != nil { start() }
        }
    }

    private func downloadToDisk(url: URL, diskKey: String) async {
        let startGeneration = generation
        guard let data = await Self.fetchData(url), generation == startGeneration else { return }
        let fileURL = diskURL.appendingPathComponent(diskKey)
        let bytesDelta = await Self.writeToDisk(data, to: fileURL)
        didWriteToDisk(fileURL: fileURL, bytesDelta: bytesDelta, generation: startGeneration)
    }

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

    private func resolve(url: URL, diskKey: String, memoryKey: String, targetPixelSize: Int?) async -> UIImage? {
        let fileURL = diskURL.appendingPathComponent(diskKey)

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

        if NetworkStatus.shared.isConnected {
#if DEBUG
            debugStats.networkRequests += 1
#endif
            if let downloaded = await download(url: url, diskKey: diskKey, memoryKey: memoryKey, targetPixelSize: targetPixelSize) {
                return downloaded
            }
        }

        if let fallback = await Self.loadFromDisk(at: fileURL, targetPixelSize: targetPixelSize, requireFullSize: false, touch: false) {
            memoryCache.setObject(fallback.image, forKey: memoryKey as NSString, cost: fallback.image.decodedCost)
            return fallback.image
        }
        return nil
    }

    private func download(url: URL, diskKey: String, memoryKey: String, targetPixelSize: Int?) async -> UIImage? {
        let startGeneration = generation
        let fetchURL = upgradedDownloadURL(from: url, minimumSize: 512)
        guard let (data, image) = await Self.fetchAndDecode(fetchURL, targetPixelSize: targetPixelSize) else {
#if DEBUG
            debugStats.networkFailures += 1
#endif
            return nil
        }
        guard generation == startGeneration else { return nil }

        memoryCache.setObject(image, forKey: memoryKey as NSString, cost: image.decodedCost)
        let fileURL = diskURL.appendingPathComponent(diskKey)
        Task(priority: .background) {
            let bytesDelta = await Self.writeToDisk(data, to: fileURL)
            self.didWriteToDisk(fileURL: fileURL, bytesDelta: bytesDelta, generation: startGeneration)
        }
#if DEBUG
        debugStats.networkSuccesses += 1
#endif
        return image
    }

    private func didWriteToDisk(fileURL: URL, bytesDelta: Int, generation writeGeneration: Int) {
        guard writeGeneration == generation else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        currentDiskBytes += bytesDelta
        trimDiskCacheIfNeeded()
    }

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

        fileInfos.sort { $0.date < $1.date }
        for info in fileInfos {
            guard totalSize > maxDiskBytes * 4 / 5 else { break }
            try? fm.removeItem(at: info.url)
            totalSize -= info.size
        }
        currentDiskBytes = totalSize
    }

    private func cacheKey(for url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

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

    private func diskCacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return cacheKey(for: url)
        }
        var changed = false
        let volatileParams: Set<String> = ["width", "height", "X-Plex-Token", "X-Plex-Client-Identifier"]
        if let items = components.queryItems,
           items.contains(where: { volatileParams.contains($0.name) }) {
            components.queryItems = items.filter { !volatileParams.contains($0.name) }
            changed = true
        }
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
        let isFullSize: Bool
    }

    @concurrent
    private static func loadFromDisk(at fileURL: URL, targetPixelSize: Int?, requireFullSize: Bool, touch: Bool) async -> DiskImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
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
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        }
        return DiskImage(image: image, isFullSize: isFullSize)
    }

    @concurrent
    private static func storedPixelSize(at fileURL: URL) async -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height)
    }

    /// Moves Plex auth params from the query string into headers (the spec's preferred
    /// form) so the token doesn't land in server or proxy access logs.
    private static func artworkRequest(for url: URL) -> URLRequest {
        let headerParams: Set<String> = ["X-Plex-Token", "X-Plex-Client-Identifier"]
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.contains(where: { headerParams.contains($0.name) }) else {
            return URLRequest(url: url)
        }
        components.queryItems = items.filter { !headerParams.contains($0.name) }
        var request = URLRequest(url: components.url ?? url)
        for item in items where headerParams.contains(item.name) {
            request.setValue(item.value, forHTTPHeaderField: item.name)
        }
        return request
    }

    @concurrent
    private static func fetchData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await downloadSession.data(for: artworkRequest(for: url)),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !data.isEmpty else { return nil }
        return data
    }

    @concurrent
    private static func fetchAndDecode(_ url: URL, targetPixelSize: Int?) async -> (Data, UIImage)? {
        guard let (data, response) = try? await downloadSession.data(for: artworkRequest(for: url)),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let image = decodeImage(from: data, targetPixelSize: targetPixelSize) else { return nil }
        return (data, image)
    }

    @concurrent
    private static func writeToDisk(_ data: Data, to fileURL: URL) async -> Int {
        let previousSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return 0 }
        return data.count - previousSize
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
