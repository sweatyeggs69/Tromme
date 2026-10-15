import SwiftUI
import UIKit
import CryptoKit

@Observable @MainActor
final class ArtworkColorCache {
    static let shared = ArtworkColorCache()

    /// Soft cap on resident entries. Colors are tiny (RGB triples), and artist colors are
    /// precomputed for the whole library, so the cap leaves room for a large collection
    /// while still bounding growth.
    private static let maxEntries = 5000

    private var cache: [String: Color] = [:]
    private var insertionOrder: [String] = []
    private let diskURL: URL
    private let persistence = ArtworkColorPersistence()
    private var saveTask: Task<Void, Never>?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskURL = caches.appendingPathComponent("TrommeColorCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        Task { await loadFromDisk() }
    }

    func color(
        for thumbPath: String?,
        colorScheme: ColorScheme,
        style: ArtworkBackdrop.Style
    ) -> Color? {
        guard let thumbPath, let source = cache[Self.key(thumbPath, style)] else { return nil }
        return ArtworkBackdrop.color(from: UIColor(source), colorScheme: colorScheme)
    }

    /// Each style is keyed separately because each uses a different color pick.
    private static func key(_ thumbPath: String, _ style: ArtworkBackdrop.Style) -> String {
        switch style {
        case .artist: "artist:" + thumbPath
        case .cover: "cover:" + thumbPath
        }
    }

    func resolveColor(
        for thumbPath: String?,
        using client: PlexAPIClient,
        server: PlexServer,
        style: ArtworkBackdrop.Style
    ) async {
        guard let thumbPath, cache[Self.key(thumbPath, style)] == nil else { return }
        // 512 matches the card bucket in ArtworkView.recommendedTranscodeSize, so this
        // reuses the image already cached for Home cards / Now Playing instead of
        // fetching a separate low-res thumbnail.
        guard let url = client.artworkURL(server: server, path: thumbPath, width: 512, height: 512) else { return }
        guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 512) else { return }
        resolveColor(for: thumbPath, from: image, style: style)
    }

    /// Picks the color from an image the caller already has, so the backdrop can appear
    /// together with that image instead of waiting on a separate fetch. The pick samples a
    /// small downscale, so the source resolution doesn't change the result.
    func resolveColor(
        for thumbPath: String?,
        from image: UIImage,
        style: ArtworkBackdrop.Style
    ) {
        guard let thumbPath, cache[Self.key(thumbPath, style)] == nil else { return }
        store(Color(Self.pick(from: image, style: style)), forKey: Self.key(thumbPath, style))
        scheduleSave()
    }

    /// Picks and saves backdrop colors for artist photos that are already in the image
    /// cache, so artist pages open with their color instead of computing it on arrival.
    /// Reads from disk only and never downloads; the library artwork pass is what puts the
    /// photos there. Safe to re-run: artists with a saved color are skipped.
    func precomputeArtistColors(thumbPaths: [String], client: PlexAPIClient, server: PlexServer) async {
        for path in thumbPaths {
            guard !Task.isCancelled, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            let key = Self.key(path, .artist)
            guard cache[key] == nil,
                  let url = client.artworkURL(server: server, path: path, width: 512, height: 512),
                  let image = await ImageCache.shared.anyCachedImage(for: url, targetPixelSize: 512) else { continue }
            // The pixel work runs off the main actor so a large library doesn't stall the UI.
            let picked = await Task.detached(priority: .utility) { Self.pick(from: image, style: .artist) }.value
            guard cache[key] == nil else { continue }
            store(Color(picked), forKey: key)
            scheduleSave()
        }
    }

    /// The color pick for each style. Pure pixel math, so it can run on any thread.
    private nonisolated static func pick(from image: UIImage, style: ArtworkBackdrop.Style) -> UIColor {
        switch style {
        case .artist: image.averageColor(visibleFraction: 0.6)
        case .cover: image.averageColor(visibleFraction: 1)
        }
    }

    /// Inserts a color and evicts the oldest entry once the cap is exceeded.
    private func store(_ color: Color, forKey key: String) {
        if cache[key] == nil {
            insertionOrder.append(key)
        }
        cache[key] = color
        while cache.count > Self.maxEntries, !insertionOrder.isEmpty {
            let evicted = insertionOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    // MARK: - Disk Persistence

    private func loadFromDisk() async {
        let fileURL = diskURL.appendingPathComponent("colors-v7.json")
        let entries = await persistence.load(from: fileURL)
        for (key, rgb) in entries where rgb.count == 3 {
            store(Color(red: rgb[0], green: rgb[1], blue: rgb[2]), forKey: key)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            flushToDisk()
        }
    }

    private func flushToDisk() {
        let fileURL = diskURL.appendingPathComponent("colors-v7.json")
        var entries: [String: [CGFloat]] = [:]
        for (key, color) in cache {
            let uiColor = UIColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
            entries[key] = [r, g, b]
        }
        Task(priority: .utility) {
            await persistence.save(entries, to: fileURL)
        }
    }
}

private extension UIImage {
    /// Overall tone of the visible part of the image (the top `visibleFraction`; artist photos
    /// fade out at the bottom): the plain average color. The backdrop re-lights it later.
    func averageColor(visibleFraction: Double) -> UIColor {
        guard let cgImage else { return .gray }

        let size = 32
        var pixelData = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixelData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .gray }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let rows = max(Int(Double(size) * visibleFraction), 1)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        for i in 0..<(rows * size) {
            sumR += Double(pixelData[i * 4]); sumG += Double(pixelData[i * 4 + 1]); sumB += Double(pixelData[i * 4 + 2])
        }
        let n = Double(rows * size) * 255
        return UIColor(red: sumR / n, green: sumG / n, blue: sumB / n, alpha: 1)
    }
}
