import SwiftUI
import UIKit
import CryptoKit

/// Turns an artwork's accent (or average) color into the page backdrop.
///
/// In light appearance, strong accents (chroma 25 or more, the same bar the pick uses) are
/// used as is, so the page matches the accent on the cover; only the text-contrast guard
/// may nudge their lightness. Everything else, including every color in dark appearance,
/// is re-lit into the Apple Music style tint.
///
/// Dark appearance: colorful sources go to L* 26 to 40 at about 0.8x chroma; neutral ones
/// to source L* + 0.5, capped at L* 42.3 (measured from Apple Music artist pages). Light
/// appearance: L* is roughly the source L* minus 7 for mid tones and 100 for white;
/// chroma and hue are kept.
enum ArtworkBackdrop {
    enum Style {
        /// Artist pages: accent or average of the visible photo.
        case artist
        /// Album and playlist pages: accent or average of the whole cover.
        case cover
    }

    private static let darkLightnessCap = 42.3
    /// Matches `minimumAccentChroma` in the color pick.
    private static let accentChroma = 25.0

    static func color(from source: UIColor, colorScheme: ColorScheme) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        source.getRed(&r, green: &g, blue: &b, alpha: nil)
        let lab = Lab(r: Double(r), g: Double(g), b: Double(b))
        if colorScheme == .light, lab.chroma >= accentChroma {
            return Color(relit(lightness: lab.l, chroma: lab.chroma, hue: lab.hue))
        }
        let ui: UIColor
        switch colorScheme {
        case .light:
            ui = relit(lightness: lightBackdropLightness(forSource: lab.l), chroma: lab.chroma >= 8 ? lab.chroma * 0.8 : lab.chroma, hue: lab.hue)
        default:
            let tint = darkTint(for: lab)
            ui = relit(lightness: tint.lightness, chroma: tint.chroma, hue: lab.hue)
        }
        return Color(ui)
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

    /// Dark-appearance target: colorful sources at L* 26 to 40 and about 0.8x chroma,
    /// neutral ones just above their own L*, capped.
    private static func darkTint(for lab: Lab) -> (lightness: Double, chroma: Double) {
        let colorful = lab.chroma >= 8
        let chroma = colorful ? lab.chroma * 0.8 : lab.chroma
        let lightness = colorful ? min(max(lab.l, 26), 40) : min(lab.l + 0.5, darkLightnessCap)
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
