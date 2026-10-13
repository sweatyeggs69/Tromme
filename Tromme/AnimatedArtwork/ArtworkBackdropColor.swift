import CoreVideo
import SwiftUI

/// Backdrop color derived from the lower part of artwork. Shared by every animated artwork
/// surface (Now Playing, album details) so they blend into the page the same way.
///
/// Matches Apple Music: the page continues the artwork's own color, light or dark,
/// and the controls flip to dark content when the color is light.
struct ArtworkBackdropColor {
    let color: Color
    /// True when black content reads better than white on `color`.
    let isLight: Bool

    /// Frames darker than this are treated as the clip's black opening frames.
    private static let blackLuminance: CGFloat = 0.03
    /// Sampled band, as fractions of the frame height: just above the very bottom edge,
    /// which some clips darken.
    private static let bandTop: CGFloat = 0.70
    private static let bandBottom: CGFloat = 0.92

    /// Returns nil for black frames so callers keep waiting for real content.
    init?(pixelBuffer buffer: CVPixelBuffer) {
        guard let sample = Self.dominantColor(in: buffer), sample.luminance >= Self.blackLuminance else { return nil }
        color = Color(red: sample.r, green: sample.g, blue: sample.b)
        isLight = color.isLightColor()
    }

    /// Most common color in the band (pixels grouped into coarse buckets, then averaged
    /// within the winning bucket), so busy artwork doesn't average out to mud.
    private static func dominantColor(in buffer: CVPixelBuffer) -> (r: CGFloat, g: CGFloat, b: CGFloat, luminance: CGFloat)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 8 else { return nil }

        var counts = [Int](repeating: 0, count: 512)
        var sums = [(r: Int, g: Int, b: Int)](repeating: (0, 0, 0), count: 512)
        var totalLuminance = 0.0
        var total = 0
        let firstRow = Int(CGFloat(height) * bandTop)
        let lastRow = Int(CGFloat(height) * bandBottom)
        for row in Swift.stride(from: firstRow, to: lastRow, by: 4) {
            let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: 4) {
                let b = Int(line[x * 4]), g = Int(line[x * 4 + 1]), r = Int(line[x * 4 + 2])
                let bucket = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
                counts[bucket] += 1
                sums[bucket].r += r
                sums[bucket].g += g
                sums[bucket].b += b
                totalLuminance += 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                total += 1
            }
        }
        guard total > 0, let best = counts.indices.max(by: { counts[$0] < counts[$1] }) else { return nil }
        let n = CGFloat(counts[best]) * 255
        return (CGFloat(sums[best].r) / n, CGFloat(sums[best].g) / n, CGFloat(sums[best].b) / n,
                CGFloat(totalLuminance / Double(total) / 255))
    }
}
