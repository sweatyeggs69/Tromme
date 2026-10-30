import SwiftUI
import UIKit
import CryptoKit

@Observable @MainActor
final class ArtworkColorCache {
    static let shared = ArtworkColorCache()

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
        if style == .artist { return ArtworkBackdrop.whiteTextColor(from: UIColor(source)) }
        return ArtworkBackdrop.color(from: UIColor(source), colorScheme: colorScheme)
    }

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
        guard let url = client.artworkURL(server: server, path: thumbPath, width: 512, height: 512) else { return }
        guard let image = await ImageCache.shared.image(for: url, targetPixelSize: 512) else { return }
        resolveColor(for: thumbPath, from: image, style: style)
    }

    func resolveColor(
        for thumbPath: String?,
        from image: UIImage,
        style: ArtworkBackdrop.Style
    ) {
        guard let thumbPath, cache[Self.key(thumbPath, style)] == nil else { return }
        store(Color(Self.pick(from: image, style: style)), forKey: Self.key(thumbPath, style))
        scheduleSave()
    }

    func precomputeArtistColors(thumbPaths: [String], client: PlexAPIClient, server: PlexServer) async {
        for path in thumbPaths {
            guard !Task.isCancelled, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            let key = Self.key(path, .artist)
            guard cache[key] == nil,
                  let url = client.artworkURL(server: server, path: path, width: 512, height: 512),
                  let image = await ImageCache.shared.anyCachedImage(for: url, targetPixelSize: 512) else { continue }
            let picked = await Task.detached(priority: .utility) { Self.pick(from: image, style: .artist) }.value
            guard cache[key] == nil else { continue }
            store(Color(picked), forKey: key)
            scheduleSave()
        }
    }

    private nonisolated static func pick(from image: UIImage, style: ArtworkBackdrop.Style) -> UIColor {
        switch style {
        case .artist: image.accentColor(rows: (2.0 / 3.0)..<1, keepsPaleAverage: false)
        case .cover: image.accentColor(rows: 0..<1, keepsPaleAverage: true)
        }
    }

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

            if lab.l <= 85 { nonWhiteCount += 1 }
            if lab.l < darkLightness {
                darkCount += 1
                darkR += r; darkG += g; darkB += b
            }

            let hueDegrees = lab.hue * 180 / .pi
            let looksLikeSkin = (20...80).contains(hueDegrees) && lab.l >= 25
            if chroma >= minimumTintChroma, (3...85).contains(lab.l), !looksLikeSkin {
                tintCount[bin] += 1
                tintR[bin] += r; tintG[bin] += g; tintB[bin] += b
            }

            guard chroma >= minimumAccentChroma, (15...95).contains(lab.l) else { continue }
            binWeight[bin] += chroma
            binCount[bin] += 1
            binR[bin] += r * chroma; binG[bin] += g * chroma; binB[bin] += b * chroma
        }

        let n = Double(pixelCount)
        let average = UIColor(red: sumR / n, green: sumG / n, blue: sumB / n, alpha: 1)
        let averageLightness = Lab(r: sumR / n, g: sumG / n, b: sumB / n).l

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
