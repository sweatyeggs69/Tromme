import CoreVideo
import SwiftUI
import UIKit

/// Backdrop color derived from the bottom of artwork. Shared by every animated artwork
/// surface (Now Playing, album details) so they blend into the page the same way.
///
/// Matches Apple Music: the page continues the artwork's own bottom color, light or dark,
/// and the controls flip to dark content when the color is light.
struct ArtworkBackdropColor {
    let color: Color
    /// True when black content reads better than white on `color`.
    let isLight: Bool

    /// Frames darker than this are treated as the clip's black opening frames.
    private static let blackLuminance: CGFloat = 0.03

    /// Returns nil for black frames so callers keep waiting for real content.
    init?(pixelBuffer buffer: CVPixelBuffer) {
        guard let average = Self.bottomAverage(of: buffer) else { return nil }
        let luminance = 0.2126 * average.r + 0.7152 * average.g + 0.0722 * average.b
        guard luminance >= Self.blackLuminance else { return nil }
        color = Color(red: average.r, green: average.g, blue: average.b)
        isLight = color.isLightColor()
    }

    /// Average of the bottom quarter of the frame, subsampled; steadier than a few edge rows.
    private static func bottomAverage(of buffer: CVPixelBuffer) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 8 else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for row in Swift.stride(from: height - height / 4, to: height, by: 4) {
            let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: 4) {
                b += Double(line[x * 4])
                g += Double(line[x * 4 + 1])
                r += Double(line[x * 4 + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (CGFloat(r / count / 255), CGFloat(g / count / 255), CGFloat(b / count / 255))
    }
}
