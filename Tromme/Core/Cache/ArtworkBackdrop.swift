import SwiftUI
import UIKit
import CryptoKit

/// Turns an artwork's accent (or average) color into the page backdrop.
///
/// Album and playlist pages keep the artwork's own color in either appearance: hue and
/// chroma are kept, lightness is clamped only enough to avoid near-black and near-white
/// pages, and neutral sources keep their lightness (a pale misty cover gives a pale page,
/// a dark one a dark page). Only the text-contrast guard may nudge lightness; the page's
/// text color follows the result.
///
/// Artist pages always carry white text, so they take the same color pulled into a dark
/// range (L* 22 to 46) with most of its chroma kept.
enum ArtworkBackdrop {
    enum Style {
        /// Artist pages: accent or average of the visible photo.
        case artist
        /// Album and playlist pages: accent or average of the whole cover.
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

    /// Backdrop that always carries white text (artist pages), in either appearance: the
    /// dark-appearance tint, darkened further if white text would fall below the contrast floor.
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

    /// White-text target: colorful sources at L* 22 to 46 keeping 0.95x chroma, neutral ones
    /// just above their own L*, capped.
    private static func darkTint(for lab: Lab) -> (lightness: Double, chroma: Double) {
        let colorful = lab.chroma >= 8
        let chroma = colorful ? lab.chroma * 0.95 : lab.chroma
        let lightness = colorful ? min(max(lab.l, 22), 46) : min(lab.l + 0.5, darkLightnessCap)
        return (lightness, chroma)
    }

    /// Smallest contrast ratio the page may offer: backdrops where neither white nor black
    /// text reaches this (roughly L* 44 to 55) are nudged to the nearest lightness that does.
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

    /// Higher of the WCAG contrast ratios of white and black text on the color.
    private static func bestTextContrast(on color: UIColor) -> Double {
        let luminance = relativeLuminance(of: color)
        return max(1.05 / (luminance + 0.05), (luminance + 0.05) / 0.05)
    }

    /// WCAG contrast ratio of white text on the color.
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
