import UIKit

/// Brightness of a logo's visible pixels, used to prefer light logos on the dark artist page.
enum ArtistLogoBrightness {
    /// Alpha-weighted mean luminance (0 = black, 1 = white) over a small downsample.
    static func score(of image: UIImage) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        var weighted = 0.0
        var alphaTotal = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0 else { continue }
            // Premultiplied: divide alpha back out to get the pixel's own color.
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            weighted += (0.2126 * r + 0.7152 * g + 0.0722 * b) * a
            alphaTotal += a
        }
        return alphaTotal > 0 ? min(weighted / alphaTotal, 1) : nil
    }
}
