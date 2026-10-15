import SwiftUI
import UIKit
import CryptoKit

@Observable @MainActor
final class ArtworkColorCache {
    static let shared = ArtworkColorCache()

    /// Soft cap on resident entries — colors are tiny (RGB triples), but the
    /// dictionary previously grew unbounded over the app's lifetime. 500 is
    /// roughly an album-listening session's worth of unique artwork.
    private static let maxEntries = 500

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

    func color(for thumbPath: String?) -> Color? {
        guard let thumbPath else { return nil }
        return cache[thumbPath]
    }

    func resolveColor(for thumbPath: String?, using client: PlexAPIClient, server: PlexServer) async {
        guard let thumbPath, cache[thumbPath] == nil else { return }
        // 512 matches the card bucket in ArtworkView.recommendedTranscodeSize, so this
        // reuses the image already cached for Home cards / Now Playing instead of
        // fetching a separate low-res thumbnail.
        guard let url = client.artworkURL(server: server, path: thumbPath, width: 512, height: 512) else { return }
        guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 512) else { return }
        let dominant = image.dominantColor
        store(Color(dominant), forKey: thumbPath)
        scheduleSave()
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
        let fileURL = diskURL.appendingPathComponent("colors.json")
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
        let fileURL = diskURL.appendingPathComponent("colors.json")
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

private actor ArtworkColorPersistence {
    func load(from fileURL: URL) -> [String: [CGFloat]] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: [CGFloat]].self, from: data) else {
            return [:]
        }
        return entries
    }

    func save(_ entries: [String: [CGFloat]], to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension UIImage {
    /// Returns the most prominent vivid color in the artwork.
    ///
    /// Bins pixels into 24 hue buckets weighted by saturation × brightness, then picks
    /// the heaviest bucket — this surfaces a real accent color rather than the muddy
    /// average of every pixel. Near-black, near-white, and gray pixels are excluded so
    /// dark backdrops and white margins don't dominate the result. Falls back to a
    /// weighted average if the artwork is essentially grayscale.
    var dominantColor: UIColor {
        guard let cgImage else { return .gray }

        let size = 80
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: size * size * 4)

        guard let context = CGContext(
            data: &pixelData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .gray }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let hueBinCount = 24
        var binWeight = [Double](repeating: 0, count: hueBinCount)
        var binR = [Double](repeating: 0, count: hueBinCount)
        var binG = [Double](repeating: 0, count: hueBinCount)
        var binB = [Double](repeating: 0, count: hueBinCount)

        var fallbackR: Double = 0
        var fallbackG: Double = 0
        var fallbackB: Double = 0
        var fallbackWeight: Double = 0

        let pixelCount = size * size
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Double(pixelData[offset]) / 255
            let g = Double(pixelData[offset + 1]) / 255
            let b = Double(pixelData[offset + 2]) / 255

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            let brightness = maxC
            let saturation = maxC == 0 ? 0 : delta / maxC

            guard brightness > 0.18, brightness < 0.96, saturation > 0.25 else {
                let w = brightness * 0.05
                fallbackR += r * w
                fallbackG += g * w
                fallbackB += b * w
                fallbackWeight += w
                continue
            }

            var hue: Double = 0
            if delta > 0 {
                if maxC == r {
                    hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
                } else if maxC == g {
                    hue = (b - r) / delta + 2
                } else {
                    hue = (r - g) / delta + 4
                }
                hue *= 60
                if hue < 0 { hue += 360 }
            }

            let bin = min(hueBinCount - 1, Int(hue / 360 * Double(hueBinCount)))
            let weight = saturation * brightness
            binWeight[bin] += weight
            binR[bin] += r * weight
            binG[bin] += g * weight
            binB[bin] += b * weight

            fallbackR += r * weight
            fallbackG += g * weight
            fallbackB += b * weight
            fallbackWeight += weight
        }

        var bestBin = -1
        var bestWeight: Double = 0
        for i in 0..<hueBinCount where binWeight[i] > bestWeight {
            bestWeight = binWeight[i]
            bestBin = i
        }

        if bestBin >= 0, binWeight[bestBin] > 0 {
            return UIColor(
                red: CGFloat(binR[bestBin] / binWeight[bestBin]),
                green: CGFloat(binG[bestBin] / binWeight[bestBin]),
                blue: CGFloat(binB[bestBin] / binWeight[bestBin]),
                alpha: 1
            )
        }

        guard fallbackWeight > 0 else { return .gray }
        return UIColor(
            red: CGFloat(fallbackR / fallbackWeight),
            green: CGFloat(fallbackG / fallbackWeight),
            blue: CGFloat(fallbackB / fallbackWeight),
            alpha: 1
        )
    }
}
