import SwiftUI

/// Draws a word-synced lyric line the way Apple Music does: each word starts
/// dimmed, a soft bright edge wipes across it as it's sung, and each letter
/// grows slightly as the edge reaches it. Words are tagged with `Timing` so
/// the line still wraps as ordinary text.
struct WordWipeTextRenderer: TextRenderer {
    struct Timing: TextAttribute {
        let start: TimeInterval
        let end: TimeInterval
    }

    var time: TimeInterval
    var isActive: Bool

    private static let dimOpacity = 0.35
    private static let sungScale = 1.05
    /// Half-width of the soft edge, as a fraction of the line height.
    private static let featherRatio = 0.35

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard isActive, let timing = run[Timing.self] else {
                    context.draw(run)
                    continue
                }
                draw(run, timing: timing, in: context)
            }
        }
    }

    private func draw(_ run: Text.Layout.Run, timing: Timing, in context: GraphicsContext) {
        let rect = run.typographicBounds.rect
        let span = max(timing.end - timing.start, 0.05)
        let progress = min(max((time - timing.start) / span, 0), 1)

        let feather = rect.height * Self.featherRatio
        // Travels from fully before the word to fully past it, so the soft
        // edge enters and leaves cleanly.
        let edge = rect.minX - feather + progress * (rect.width + 2 * feather)
        var bright = context
        if progress > 0 {
            bright.clipToLayer { mask in
                mask.fill(
                    Path(rect.insetBy(dx: -feather, dy: -rect.height)),
                    with: .linearGradient(
                        Gradient(colors: [.white, .clear]),
                        startPoint: CGPoint(x: edge - feather, y: rect.midY),
                        endPoint: CGPoint(x: edge + feather, y: rect.midY)
                    )
                )
            }
        }

        // Each letter grows as the wipe's edge passes over it.
        for letter in run {
            let bounds = letter.typographicBounds.rect
            let letterProgress = min(max((edge - (bounds.minX - feather)) / (bounds.width + 2 * feather), 0), 1)
            let scale = 1 + (Self.sungScale - 1) * (1 - pow(1 - letterProgress, 3))

            var dim = context
            Self.scale(&dim, by: scale, around: bounds)
            dim.opacity *= Self.dimOpacity
            dim.draw(letter)

            guard progress > 0 else { continue }
            var lit = bright
            Self.scale(&lit, by: scale, around: bounds)
            lit.draw(letter)
        }
    }

    private static func scale(_ context: inout GraphicsContext, by scale: Double, around rect: CGRect) {
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.midX, y: -rect.midY)
    }
}
