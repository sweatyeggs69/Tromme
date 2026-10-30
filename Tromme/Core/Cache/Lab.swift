import SwiftUI
import UIKit
import CryptoKit

struct Lab {
    let l: Double, a: Double, b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }
    var hue: Double { atan2(b, a) }

    private static let white = (x: 0.95047, y: 1.0, z: 1.08883)

    init(r: Double, g: Double, b: Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (lin(r), lin(g), lin(b))
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / Self.white.x
        let y = (0.2126 * lr + 0.7152 * lg + 0.0722 * lb) / Self.white.y
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / Self.white.z
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        l = 116 * f(y) - 16
        a = 500 * (f(x) - f(y))
        self.b = 200 * (f(y) - f(z))
    }

    static func rgb(lightness: Double, chroma: Double, hue: Double) -> UIColor {
        func finv(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116) / 7.787 }
        func enc(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        func convert(_ c: Double) -> (Double, Double, Double) {
            let fy = (lightness + 16) / 116
            let fx = fy + c * cos(hue) / 500
            let fz = fy - c * sin(hue) / 200
            let x = finv(fx) * white.x, y = finv(fy) * white.y, z = finv(fz) * white.z
            return (
                3.2406 * x - 1.5372 * y - 0.4986 * z,
                -0.9689 * x + 1.8758 * y + 0.0415 * z,
                0.0557 * x - 0.2040 * y + 1.0570 * z
            )
        }
        var c = chroma
        var lin = convert(c)
        while c > 0, [lin.0, lin.1, lin.2].contains(where: { $0 < 0 || $0 > 1 }) {
            c -= 0.5
            lin = convert(max(c, 0))
        }
        return UIColor(
            red: CGFloat(enc(min(max(lin.0, 0), 1))),
            green: CGFloat(enc(min(max(lin.1, 0), 1))),
            blue: CGFloat(enc(min(max(lin.2, 0), 1))),
            alpha: 1
        )
    }
}
