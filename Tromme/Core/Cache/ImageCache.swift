import SwiftUI
import CryptoKit

/// Two-tier image cache: NSCache (memory) + disk (Caches directory).
/// Images are keyed by URL string, hashed to SHA256 for disk filenames.
actor ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskURL: URL
    private let maxDiskBytes: Int = 500 * 1024 * 1024 // 500 MB

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskURL = caches.appendingPathComponent("TrommeImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    // MARK: - Public API

    func image(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)

        // 1. Memory
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // 2. Disk
        if let diskImage = loadFromDisk(key: key) {
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: diskImage.diskCost)
            return diskImage
        }

        // 3. Network
        return await download(url: url, key: key)
    }

    func prefetch(urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(20) {
                group.addTask {
                    _ = await self.image(for: url)
                }
            }
        }
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskURL)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
    }

    // MARK: - Private

    private func download(url: URL, key: String) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }

            memoryCache.setObject(image, forKey: key as NSString, cost: data.count)
            saveToDisk(data: data, key: key)
            return image
        } catch {
            return nil
        }
    }

    private func loadFromDisk(key: String) -> UIImage? {
        let fileURL = diskURL.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Touch the file to update access time for LRU eviction
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
        return UIImage(data: data)
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
}

private extension UIImage {
    var diskCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
