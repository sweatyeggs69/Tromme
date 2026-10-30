import SwiftUI
import UIKit
import CryptoKit

enum ArtworkBackdrop {
    enum Style {
        case artist
        case cover
    }

    private static let darkLightnessCap = 42.3

    static func color(from source: UIColor, colorScheme: ColorScheme) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        source.getRed(&r, green: &g, blue: &b, alpha: nil)
        let lab = Lab(r: Double(r), g: Double(g), b: Double(b))
        let lightness = lab.chroma >= 8 ? min(max(lab.l, 20), 90) : lab.l
        return Color(relit(lightness: lightness, chroma: lab.chroma, hue: lab.hue))
    }

    static func whiteTextColor(from source: UIColor) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        source.getRed(&r, green: &g, blue: &b, alpha: nil)
        let lab = Lab(r: Double(r), g: Double(g), b: Double(b))
        let tint = darkTint(for: lab)
        var lightness = tint.lightness
        var color = Lab.rgb(lightness: lightness, chroma: tint.chroma, hue: lab.hue)
        while lightness > 0, whiteTextContrast(on: color) < minimumTextContrast {
            lightness -= 0.5
            color = Lab.rgb(lightness: lightness, chroma: tint.chroma, hue: lab.hue)
        }
        return Color(color)
    }

    private static func darkTint(for lab: Lab) -> (lightness: Double, chroma: Double) {
        let colorful = lab.chroma >= 8
        let chroma = colorful ? lab.chroma * 0.95 : lab.chroma
        let lightness = colorful ? min(max(lab.l, 22), 46) : min(lab.l + 0.5, darkLightnessCap)
        return (lightness, chroma)
    }

    private static let minimumTextContrast = 5.5

    private static func relit(lightness: Double, chroma: Double, hue: Double) -> UIColor {
        var step = 0.0
        while step <= 30 {
            for candidate in [lightness - step, lightness + step] where (0...100).contains(candidate) {
                let color = Lab.rgb(lightness: candidate, chroma: chroma, hue: hue)
                if bestTextContrast(on: color) >= minimumTextContrast { return color }
            }
            step += 0.5
        }
        return Lab.rgb(lightness: lightness, chroma: chroma, hue: hue)
    }

    private static func bestTextContrast(on color: UIColor) -> Double {
        let luminance = relativeLuminance(of: color)
        return max(1.05 / (luminance + 0.05), (luminance + 0.05) / 0.05)
    }

    private static func whiteTextContrast(on color: UIColor) -> Double {
        1.05 / (relativeLuminance(of: color) + 0.05)
    }

    private static func relativeLuminance(of color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
