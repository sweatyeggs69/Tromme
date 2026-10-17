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
        // Artist pages always carry white text, so their backdrop ignores the appearance.
        if style == .artist { return ArtworkBackdrop.whiteTextColor(from: UIColor(source)) }
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
        case .artist: image.accentColor(rows: (2.0 / 3.0)..<1, keepsPaleAverage: false)
        case .cover: image.accentColor(rows: 0..<1, keepsPaleAverage: true)
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
        let fileURL = diskURL.appendingPathComponent("colors-v16.json")
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
        let fileURL = diskURL.appendingPathComponent("colors-v16.json")
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
    /// Backdrop source color for a band of the image (`rows`, as fractions of its height; artist
    /// pages sample the bottom third, where the photo fades into the page). Favors a strong accent: when vivid pixels of
    /// one hue family cover at least `minimumAccentShare` of the image (the red grenade on
    /// American Idiot, the gold logo on Dookie), returns their chroma-weighted average.
    /// Otherwise, when muted but tinted pixels of one hue family cover at least
    /// `minimumTintShare` of the non-white pixels (the dark green wall behind Weezer's white
    /// jumpsuits, The 1975's dark suits), returns their average, so a colored area isn't
    /// washed out to gray by bright subjects or a white studio backdrop. Otherwise, when dark
    /// pixels cover at least `minimumDarkShare` of the non-white pixels, returns their
    /// average (a dark subject on a light backdrop gives a deep page, as on Apple Music; a
    /// black-and-white photo needs only `minimumAchromaticDarkShare` of them).
    /// With `keepsPaleAverage` (covers only; artist pages carry white text and need a dark
    /// page, so a white studio photo must not take this path), a pale, desaturated image
    /// (average L* 70+, little dark area) returns its plain average before the tint and dark picks, so it gives a pale page. Otherwise returns the plain
    /// average color. The backdrop keeps its hue and chroma.
    func accentColor(rows: Range<Double>, keepsPaleAverage: Bool) -> UIColor {
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

        let hueBins = 24
        let minimumAccentChroma = 25.0
        let minimumAccentShare = 0.04
        let minimumTintChroma = 4.0
        let minimumTintShare = 0.15
        let darkLightness = 25.0
        let minimumDarkShare = 0.25
        // A black-and-white photo has no hue to pick, so a smaller dark area is enough to
        // call the backdrop black (Being as an Ocean: dark shirts and hair on white).
        let achromaticShare = 0.05
        let minimumAchromaticDarkShare = 0.10
        let paleAverageLightness = 70.0
        let paleMaximumDarkShare = 0.20

        let firstRow = min(Int(Double(size) * rows.lowerBound), size - 1)
        let lastRow = max(Int(Double(size) * rows.upperBound), firstRow + 1)
        let firstPixel = firstRow * size
        let pixelCount = (lastRow - firstRow) * size
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var binWeight = [Double](repeating: 0, count: hueBins)
        var binCount = [Int](repeating: 0, count: hueBins)
        var binR = [Double](repeating: 0, count: hueBins)
        var binG = [Double](repeating: 0, count: hueBins)
        var binB = [Double](repeating: 0, count: hueBins)
        var tintCount = [Double](repeating: 0, count: hueBins)
        var nonWhiteCount = 0.0
        var sumChroma = 0.0
        var chromaticCount = 0.0
        var darkCount = 0.0, darkR = 0.0, darkG = 0.0, darkB = 0.0
        var tintR = [Double](repeating: 0, count: hueBins)
        var tintG = [Double](repeating: 0, count: hueBins)
        var tintB = [Double](repeating: 0, count: hueBins)

        for i in firstPixel..<(firstPixel + pixelCount) {
            let r = Double(pixelData[i * 4]) / 255
            let g = Double(pixelData[i * 4 + 1]) / 255
            let b = Double(pixelData[i * 4 + 2]) / 255
            sumR += r; sumG += g; sumB += b

            let lab = Lab(r: r, g: g, b: b)
            let chroma = lab.chroma
            sumChroma += chroma
            if chroma >= minimumTintChroma { chromaticCount += 1 }
            let bin = Int((lab.hue + .pi) / (2 * .pi) * Double(hueBins)) % hueBins

            // A white studio backdrop or blown highlights shouldn't dilute the colors below.
            if lab.l <= 85 { nonWhiteCount += 1 }
            if lab.l < darkLightness {
                darkCount += 1
                darkR += r; darkG += g; darkB += b
            }

            // Tinted pixels: any visible hue, dark ones included (black suits read as a deep
            // navy, as on Apple Music), skipping grays, pure black and highlights. Skin tones
            // are skipped too: faces are the subject, not the backdrop, and would otherwise
            // turn band photos brown.
            let hueDegrees = lab.hue * 180 / .pi
            let looksLikeSkin = (20...80).contains(hueDegrees) && lab.l >= 25
            if chroma >= minimumTintChroma, (3...85).contains(lab.l), !looksLikeSkin {
                tintCount[bin] += 1
                tintR[bin] += r; tintG[bin] += g; tintB[bin] += b
            }

            // Vivid pixels only: skip grays, near-black and near-white.
            guard chroma >= minimumAccentChroma, (15...95).contains(lab.l) else { continue }
            binWeight[bin] += chroma
            binCount[bin] += 1
            binR[bin] += r * chroma; binG[bin] += g * chroma; binB[bin] += b * chroma
        }

        let n = Double(pixelCount)
        let average = UIColor(red: sumR / n, green: sumG / n, blue: sumB / n, alpha: 1)
        let averageLightness = Lab(r: sumR / n, g: sumG / n, b: sumB / n).l

        // A hue family is a bin plus its neighbors, so an accent split across a bin edge
        // still counts as one.
        func family(_ bin: Int) -> [Int] { [(bin + hueBins - 1) % hueBins, bin, (bin + 1) % hueBins] }
        func total(_ values: [Double], over bins: [Int]) -> Double {
            var sum = 0.0
            for bin in bins { sum += values[bin] }
            return sum
        }
        func bestFamily(by values: [Double]) -> [Int] {
            var best = 0
            for bin in 1..<hueBins where total(values, over: family(bin)) > total(values, over: family(best)) {
                best = bin
            }
            return family(best)
        }

        let bins = bestFamily(by: binWeight)
        let weight = total(binWeight, over: bins)
        let share = total(binCount.map(Double.init), over: bins) / n
        guard weight > 0, share >= minimumAccentShare else {
            // A pale, desaturated image (a misty Witcher cover) keeps its pale average instead
            // of having its few darker pixels picked, unless it holds a real dark subject.
            if keepsPaleAverage, averageLightness >= paleAverageLightness, darkCount / n < paleMaximumDarkShare, sumChroma / n < 12 {
                return average
            }
            let tintBins = bestFamily(by: tintCount)
            let tintTotal = total(tintCount, over: tintBins)
            let nonWhite = max(nonWhiteCount, 1)
            guard tintTotal / nonWhite >= minimumTintShare else {
                let isAchromatic = chromaticCount / n < achromaticShare
                let darkShare = isAchromatic ? minimumAchromaticDarkShare : minimumDarkShare
                guard darkCount / nonWhite >= darkShare else { return average }
                return UIColor(red: darkR / darkCount, green: darkG / darkCount, blue: darkB / darkCount, alpha: 1)
            }
            return UIColor(
                red: total(tintR, over: tintBins) / tintTotal,
                green: total(tintG, over: tintBins) / tintTotal,
                blue: total(tintB, over: tintBins) / tintTotal,
                alpha: 1
            )
        }
        return UIColor(
            red: total(binR, over: bins) / weight,
            green: total(binG, over: bins) / weight,
            blue: total(binB, over: bins) / weight,
            alpha: 1
        )
    }
}
