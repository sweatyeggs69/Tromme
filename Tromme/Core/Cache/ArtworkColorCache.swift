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

    func color(
        for thumbPath: String?,
        colorScheme: ColorScheme,
        style: ArtworkBackdrop.Style = .original
    ) -> Color? {
        guard let thumbPath, let source = cache[Self.key(thumbPath, style)] else { return nil }
        return ArtworkBackdrop.color(from: UIColor(source), colorScheme: colorScheme, style: style)
    }

    /// Artist photos are keyed separately because they use a different color pick.
    private static func key(_ thumbPath: String, _ style: ArtworkBackdrop.Style) -> String {
        style == .artist ? "artist:" + thumbPath : "orig:" + thumbPath
    }

    func resolveColor(
        for thumbPath: String?,
        using client: PlexAPIClient,
        server: PlexServer,
        style: ArtworkBackdrop.Style = .original
    ) async {
        guard let thumbPath, cache[Self.key(thumbPath, style)] == nil else { return }
        // 512 matches the card bucket in ArtworkView.recommendedTranscodeSize, so this
        // reuses the image already cached for Home cards / Now Playing instead of
        // fetching a separate low-res thumbnail.
        guard let url = client.artworkURL(server: server, path: thumbPath, width: 512, height: 512) else { return }
        guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 512) else { return }
        let dominant = style == .artist ? image.vividPhotoColor(visibleFraction: 0.6) : image.originalDominantColor
        store(Color(dominant), forKey: Self.key(thumbPath, style))
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
        let fileURL = diskURL.appendingPathComponent("colors-v5.json")
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
        let fileURL = diskURL.appendingPathComponent("colors-v5.json")
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
    /// Returns the most prominent vivid color in the artwork.
    ///
    /// Bins pixels into 24 hue buckets weighted by saturation × brightness, then picks
    /// the heaviest bucket — this surfaces a real accent color rather than the muddy
    /// average of every pixel. Near-black, near-white, and gray pixels are excluded so
    /// dark backdrops and white margins don't dominate the result. Falls back to a
    /// weighted average if the artwork is essentially grayscale.
    var originalDominantColor: UIColor {
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

    /// Backdrop color: the most colorful large area of the visible part of the image (the top
    /// `visibleFraction`; artist photos fade out at the bottom), ignoring near-neutral pixels. Region score is pixel count times mean chroma,
    /// over a 16-level RGB grid with neighbours merged. Photos that are essentially neutral
    /// (black and white, or white walls and black clothing only) fall back to `dominantColor`.
    /// Warm hues are skipped when anything else is colorful (see `pick`).
    func vividPhotoColor(visibleFraction: Double) -> UIColor {
        guard let cgImage else { return .gray }

        let size = 64
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

        let levels = 16
        let minChroma = 8.0
        let rows = Int(Double(size) * visibleFraction)
        // Orange, yellow and olive turn brown once re-lit to a dark backdrop, so they only count
        // when nothing else is colorful; then the result is pushed toward a warm neutral.
        func pick(excludeWarm: Bool) -> UIColor? {
            var count = [Double](repeating: 0, count: levels * levels * levels)
            var chromaSum = [Double](repeating: 0, count: levels * levels * levels)
            @inline(__always) func bin(_ r: Int, _ g: Int, _ b: Int) -> Int { (r * levels + g) * levels + b }

            var chromaticPixels = 0
            for y in 0..<rows {
                for x in 0..<size {
                    let o = (y * size + x) * 4
                    let lab = Lab(r: Double(pixelData[o]) / 255, g: Double(pixelData[o + 1]) / 255, b: Double(pixelData[o + 2]) / 255)
                    guard lab.chroma >= minChroma, !(excludeWarm && lab.isWarm) else { continue }
                    chromaticPixels += 1
                    let i = bin(Int(pixelData[o]) >> 4, Int(pixelData[o + 1]) >> 4, Int(pixelData[o + 2]) >> 4)
                    count[i] += 1
                    chromaSum[i] += lab.chroma
                }
            }

            // Too little color to call it a colorful photo.
            guard chromaticPixels > rows * size / 20 else { return nil }

            var bestBin = 0
            var bestScore = -1.0
            for r in 0..<levels { for g in 0..<levels { for b in 0..<levels {
                var n = 0.0, c = 0.0
                for dr in -1...1 { for dg in -1...1 { for db in -1...1 {
                    let rr = r + dr, gg = g + dg, bb = b + db
                    guard (0..<levels).contains(rr), (0..<levels).contains(gg), (0..<levels).contains(bb) else { continue }
                    n += count[bin(rr, gg, bb)]
                    c += chromaSum[bin(rr, gg, bb)]
                } } }
                guard n > 0 else { continue }
                let score = n * (c / n)
                if score > bestScore { bestScore = score; bestBin = bin(r, g, b) }
            } } }
            let bestR = bestBin / (levels * levels)
            let bestG = (bestBin / levels) % levels
            let bestB = bestBin % levels

            var sumR = 0.0, sumG = 0.0, sumB = 0.0, n = 0.0
            for y in 0..<rows {
                for x in 0..<size {
                    let o = (y * size + x) * 4
                    let r = Int(pixelData[o]) >> 4, g = Int(pixelData[o + 1]) >> 4, b = Int(pixelData[o + 2]) >> 4
                    guard abs(r - bestR) <= 1, abs(g - bestG) <= 1, abs(b - bestB) <= 1 else { continue }
                    let lab = Lab(r: Double(pixelData[o]) / 255, g: Double(pixelData[o + 1]) / 255, b: Double(pixelData[o + 2]) / 255)
                    guard lab.chroma >= minChroma, !(excludeWarm && lab.isWarm) else { continue }
                    sumR += Double(pixelData[o]); sumG += Double(pixelData[o + 1]); sumB += Double(pixelData[o + 2]); n += 1
                }
            }
            guard n > 0 else { return nil }
            return UIColor(red: sumR / n / 255, green: sumG / n / 255, blue: sumB / n / 255, alpha: 1)
        }

        if let color = pick(excludeWarm: true) { return color }
        if let warm = pick(excludeWarm: false) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            warm.getRed(&r, green: &g, blue: &b, alpha: nil)
            let lab = Lab(r: Double(r), g: Double(g), b: Double(b))
            return Lab.rgb(lightness: lab.l, chroma: min(lab.chroma, 6), hue: lab.hue)
        }
        return dominantColor
    }

    /// Apple Music style album backdrop color.
    ///
    /// Measured from Apple Music album-detail screenshots: the page tint is the artwork's
    /// dominant color (the most common color, not the most vivid accent, so small bright
    /// accents on a mostly black/white cover are ignored and neutral covers stay neutral),
    /// clamped to a dark CIELAB lightness (L* 8.5 to 18.5, so light and mid covers sit at 18.5 and dark covers stay darker) while keeping its hue and
    /// chroma. Low-chroma pale colors therefore become a visibly tinted dark color.
    var dominantColor: UIColor {
        guard let cgImage else { return .gray }

        let size = 64
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

        // Histogram on an 16x16x16 grid, then take the densest bin plus its neighbours so a
        // gradient-y region (sky, paper) counts as one color instead of splitting.
        let levels = 16
        var counts = [Int](repeating: 0, count: levels * levels * levels)
        @inline(__always) func bin(_ r: Int, _ g: Int, _ b: Int) -> Int { (r * levels + g) * levels + b }
        for i in 0..<(size * size) {
            let o = i * 4
            counts[bin(Int(pixelData[o]) >> 4, Int(pixelData[o + 1]) >> 4, Int(pixelData[o + 2]) >> 4)] += 1
        }

        var bestBin = 0
        var bestScore = -1
        for r in 0..<levels { for g in 0..<levels { for b in 0..<levels {
            var score = 0
            for dr in -1...1 { for dg in -1...1 { for db in -1...1 {
                let rr = r + dr, gg = g + dg, bb = b + db
                guard (0..<levels).contains(rr), (0..<levels).contains(gg), (0..<levels).contains(bb) else { continue }
                score += counts[bin(rr, gg, bb)]
            } } }
            if score > bestScore { bestScore = score; bestBin = bin(r, g, b) }
        } } }
        let bestR = bestBin / (levels * levels)
        let bestG = (bestBin / levels) % levels
        let bestB = bestBin % levels

        var sumR = 0.0, sumG = 0.0, sumB = 0.0, n = 0.0
        for i in 0..<(size * size) {
            let o = i * 4
            let r = Int(pixelData[o]) >> 4, g = Int(pixelData[o + 1]) >> 4, b = Int(pixelData[o + 2]) >> 4
            guard abs(r - bestR) <= 1, abs(g - bestG) <= 1, abs(b - bestB) <= 1 else { continue }
            sumR += Double(pixelData[o]); sumG += Double(pixelData[o + 1]); sumB += Double(pixelData[o + 2]); n += 1
        }
        guard n > 0 else { return .gray }

        return UIColor(red: sumR / n / 255, green: sumG / n / 255, blue: sumB / n / 255, alpha: 1)
    }
}
