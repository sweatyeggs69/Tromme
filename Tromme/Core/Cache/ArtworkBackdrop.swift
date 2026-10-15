import SwiftUI
import UIKit
import CryptoKit

/// Re-lights an artwork's dominant color into the Apple Music style backdrop tint.
///
/// Dark appearance: L* = source L* + 0.5 capped at 18.5, chroma and hue kept (near-black
/// covers stay near black). Light appearance: L* is roughly the source L* minus 7 for mid
/// covers and 100 for white covers; chroma and hue are kept (same as dark). Dark covers in light mode follow the dark-mode
/// values (assumed, not yet measured).
///
/// The artist page uses the average color of the photo (see
/// `averageColor`) and re-lights it to L* 26 to 40 at about 0.8x chroma; neutral photos
/// fall back to the album recipe with a higher dark-mode cap (L* 42.3, measured from Apple
/// Music artist pages).
enum ArtworkBackdrop {
    enum Style {
        /// Album and playlist pages: the original hue-bucket pick, used as is.
        case original, artist

        var darkLightnessCap: Double { self == .artist ? 42.3 : 18.5 }
    }

    static func color(from source: UIColor, colorScheme: ColorScheme, style: Style = .original) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        source.getRed(&r, green: &g, blue: &b, alpha: nil)
        if style == .original { return Color(source) }
        let lab = Lab(r: Double(r), g: Double(g), b: Double(b))
        let ui: UIColor
        switch colorScheme {
        case .light:
            ui = relit(lightness: lightBackdropLightness(forSource: lab.l), chroma: lab.chroma >= 8 ? lab.chroma * 0.8 : lab.chroma, hue: lab.hue)
        default:
            let colorful = lab.chroma >= 8
            let chroma = colorful ? lab.chroma * 0.8 : lab.chroma
            if style == .artist && colorful {
                ui = relit(lightness: min(max(lab.l, 26), 40), chroma: chroma, hue: lab.hue)
            } else {
                ui = relit(lightness: min(lab.l + 0.5, style.darkLightnessCap), chroma: chroma, hue: lab.hue)
            }
        }
        return Color(ui)
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
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return max(1.05 / (luminance + 0.05), (luminance + 0.05) / 0.05)
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
