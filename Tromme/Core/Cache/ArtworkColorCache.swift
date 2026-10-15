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
        style: ArtworkBackdrop.Style = .album
    ) -> Color? {
        guard let thumbPath, let source = cache[Self.key(thumbPath, style)] else { return nil }
        return ArtworkBackdrop.color(from: UIColor(source), colorScheme: colorScheme, style: style)
    }

    /// Artist photos are keyed separately because they use a different color pick.
    private static func key(_ thumbPath: String, _ style: ArtworkBackdrop.Style) -> String {
        style == .artist ? "artist:" + thumbPath : "vivid:" + thumbPath
    }

    func resolveColor(
        for thumbPath: String?,
        using client: PlexAPIClient,
        server: PlexServer,
        style: ArtworkBackdrop.Style = .album
    ) async {
        guard let thumbPath, cache[Self.key(thumbPath, style)] == nil else { return }
        // 512 matches the card bucket in ArtworkView.recommendedTranscodeSize, so this
        // reuses the image already cached for Home cards / Now Playing instead of
        // fetching a separate low-res thumbnail.
        guard let url = client.artworkURL(server: server, path: thumbPath, width: 512, height: 512) else { return }
        guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 512) else { return }
        let dominant = image.vividPhotoColor(visibleFraction: style == .artist ? 0.6 : 1.0)
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
        let fileURL = diskURL.appendingPathComponent("colors-v4.json")
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
        let fileURL = diskURL.appendingPathComponent("colors-v4.json")
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
    /// Backdrop color: the most colorful large area of the visible part of the image (the top
    /// `visibleFraction`; artist photos fade out at the bottom), ignoring near-neutral pixels. Region score is pixel count times mean chroma,
    /// over a 16-level RGB grid with neighbours merged. Photos that are essentially neutral
    /// (black and white, or white walls and black clothing only) fall back to `dominantColor`.
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
        var count = [Double](repeating: 0, count: levels * levels * levels)
        var chromaSum = [Double](repeating: 0, count: levels * levels * levels)
        @inline(__always) func bin(_ r: Int, _ g: Int, _ b: Int) -> Int { (r * levels + g) * levels + b }

        var chromaticPixels = 0
        for y in 0..<rows {
            for x in 0..<size {
                let o = (y * size + x) * 4
                let lab = Lab(r: Double(pixelData[o]) / 255, g: Double(pixelData[o + 1]) / 255, b: Double(pixelData[o + 2]) / 255)
                guard lab.chroma >= minChroma else { continue }
                chromaticPixels += 1
                let i = bin(Int(pixelData[o]) >> 4, Int(pixelData[o + 1]) >> 4, Int(pixelData[o + 2]) >> 4)
                count[i] += 1
                chromaSum[i] += lab.chroma
            }
        }

        // Too little color to call it a colorful photo.
        guard chromaticPixels > rows * size / 20 else { return dominantColor }

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
                guard lab.chroma >= minChroma else { continue }
                sumR += Double(pixelData[o]); sumG += Double(pixelData[o + 1]); sumB += Double(pixelData[o + 2]); n += 1
            }
        }
        guard n > 0 else { return dominantColor }
        return UIColor(red: sumR / n / 255, green: sumG / n / 255, blue: sumB / n / 255, alpha: 1)
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

/// Re-lights an artwork's dominant color into the Apple Music style backdrop tint.
///
/// Dark appearance: L* = source L* + 0.5 capped at 18.5, chroma and hue kept (near-black
/// covers stay near black). Light appearance: L* is roughly the source L* minus 7 for mid
/// covers and 100 for white covers; chroma and hue are kept (same as dark). Dark covers in light mode follow the dark-mode
/// values (assumed, not yet measured).
///
/// The artist page picks the most colorful large area of the photo (see
/// `vividPhotoColor`) and re-lights it to L* 26 to 40 at about 0.8x chroma; neutral photos
/// fall back to the album recipe with a higher dark-mode cap (L* 42.3, measured from Apple
/// Music artist pages).
enum ArtworkBackdrop {
    enum Style {
        case album, artist

        var darkLightnessCap: Double { self == .artist ? 42.3 : 18.5 }
    }

    static func color(from source: UIColor, colorScheme: ColorScheme, style: Style = .album) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        source.getRed(&r, green: &g, blue: &b, alpha: nil)
        let lab = Lab(r: Double(r), g: Double(g), b: Double(b))
        let ui: UIColor
        switch colorScheme {
        case .light:
            ui = Lab.rgb(lightness: lightBackdropLightness(forSource: lab.l), chroma: lab.chroma >= 8 ? lab.chroma * 0.8 : lab.chroma, hue: lab.hue)
        default:
            let colorful = lab.chroma >= 8
            let chroma = colorful ? lab.chroma * 0.8 : lab.chroma
            if style == .artist && colorful {
                ui = Lab.rgb(lightness: min(max(lab.l, 26), 40), chroma: chroma, hue: lab.hue)
            } else {
                ui = Lab.rgb(lightness: min(lab.l + 0.5, style.darkLightnessCap), chroma: chroma, hue: lab.hue)
            }
        }
        return Color(ui)
    }

    /// Piecewise-linear fit through measured (source L*, backdrop L*) pairs; white covers
    /// map to a white page.
    private static func lightBackdropLightness(forSource l: Double) -> Double {
        let anchors: [(src: Double, out: Double)] = [
            (0, 0.5), (18, 18.5), (50, 43), (85, 78), (99.3, 100), (100, 100)
        ]
        for (a, b) in zip(anchors, anchors.dropFirst()) where l <= b.src {
            let t = (l - a.src) / (b.src - a.src)
            return a.out + t * (b.out - a.out)
        }
        return 100
    }
}

private struct Lab {
    let l: Double, a: Double, b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }
    var hue: Double { atan2(b, a) }

    private static let white = (x: 0.95047, y: 1.0, z: 1.08883)

    /// From gamma-encoded sRGB in 0...1.
    init(r: Double, g: Double, b: Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (lin(r), lin(g), lin(b))
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / Self.white.x
        let y = (0.2126 * lr + 0.7152 * lg + 0.0722 * lb) / Self.white.y
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / Self.white.z
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        l = 116 * f(y) - 16
        a = 500 * (f(x) - f(y))
        self.b = 200 * (f(y) - f(z))
    }

    /// sRGB color at the given L*, chroma and hue (radians); chroma is reduced until in gamut.
    static func rgb(lightness: Double, chroma: Double, hue: Double) -> UIColor {
        func finv(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116) / 7.787 }
        func enc(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        func convert(_ c: Double) -> (Double, Double, Double) {
            let fy = (lightness + 16) / 116
            let fx = fy + c * cos(hue) / 500
            let fz = fy - c * sin(hue) / 200
            let x = finv(fx) * white.x, y = finv(fy) * white.y, z = finv(fz) * white.z
            return (
                3.2406 * x - 1.5372 * y - 0.4986 * z,
                -0.9689 * x + 1.8758 * y + 0.0415 * z,
                0.0557 * x - 0.2040 * y + 1.0570 * z
            )
        }
        var c = chroma
        var lin = convert(c)
        while c > 0, [lin.0, lin.1, lin.2].contains(where: { $0 < 0 || $0 > 1 }) {
            c -= 0.5
            lin = convert(max(c, 0))
        }
        return UIColor(
            red: CGFloat(enc(min(max(lin.0, 0), 1))),
            green: CGFloat(enc(min(max(lin.1, 0), 1))),
            blue: CGFloat(enc(min(max(lin.2, 0), 1))),
            alpha: 1
        )
    }
}
