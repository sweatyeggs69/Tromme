import SwiftUI
import UIKit
import CryptoKit

@Observable @MainActor
final class ArtworkColorCache {
    static let shared = ArtworkColorCache()

    private var cache: [String: Color] = [:]
    private let diskURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskURL = caches.appendingPathComponent("TrommeColorCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        loadFromDisk()
    }

    func color(for thumbPath: String?) -> Color? {
        guard let thumbPath else { return nil }
        return cache[thumbPath]
    }

    func resolveColor(for thumbPath: String?, using client: PlexAPIClient, server: PlexServer) async {
        guard let thumbPath, cache[thumbPath] == nil else { return }
        guard let url = client.artworkURL(server: server, path: thumbPath, width: 50, height: 50) else { return }
        guard let image = await ImageCache.shared.image(for: url) else { return }
        let dominant = image.dominantColor
        let color = Color(dominant)
        cache[thumbPath] = color
        saveToDisk(thumbPath: thumbPath, r: dominant.rgbComponents.r, g: dominant.rgbComponents.g, b: dominant.rgbComponents.b)
    }

    // MARK: - Disk Persistence

    private func loadFromDisk() {
        let fileURL = diskURL.appendingPathComponent("colors.json")
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: [CGFloat]].self, from: data) else { return }
        for (key, rgb) in entries where rgb.count == 3 {
            cache[key] = Color(red: rgb[0], green: rgb[1], blue: rgb[2])
        }
    }

    private func saveToDisk(thumbPath: String, r: CGFloat, g: CGFloat, b: CGFloat) {
        let fileURL = diskURL.appendingPathComponent("colors.json")
        var entries: [String: [CGFloat]] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode([String: [CGFloat]].self, from: data) {
            entries = existing
        }
        entries[thumbPath] = [r, g, b]
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private extension UIImage {
    var dominantColor: UIColor {
        guard let cgImage else { return .gray }

        let width = 10
        let height = 10
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .gray }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        let count = width * height

        for i in 0..<count {
            let offset = i * 4
            totalR += CGFloat(pixelData[offset])
            totalG += CGFloat(pixelData[offset + 1])
            totalB += CGFloat(pixelData[offset + 2])
        }

        let n = CGFloat(count)
        return UIColor(
            red: totalR / (n * 255),
            green: totalG / (n * 255),
            blue: totalB / (n * 255),
            alpha: 1
        )
    }
}

private extension UIColor {
    var rgbComponents: (r: CGFloat, g: CGFloat, b: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r, g, b)
    }
}
