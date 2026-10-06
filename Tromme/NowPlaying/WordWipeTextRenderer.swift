import SwiftUI

/// Draws a word-synced lyric line the way Apple Music does: each word starts
/// dimmed, a soft bright edge wipes across it as it's sung, and each letter
/// scales up to full size as the edge reaches it. Words are tagged with
/// `Timing` so the line still wraps as ordinary text.
///
/// `activeAmount` animates between 0 (inactive) and 1 (active), so when the
/// line hands off to the next one the highlight fades out and the letters
/// settle back instead of snapping.
struct WordWipeTextRenderer: TextRenderer {
    struct Timing: TextAttribute {
        let start: TimeInterval
        let end: TimeInterval
    }

    var time: TimeInterval
    var activeAmount: Double
    /// How much a sung letter grows, relative to the line's own scale.
    var letterScale: Double

    var animatableData: Double {
        get { activeAmount }
        set { activeAmount = newValue }
    }

    /// Unsung and inactive text, matching other inactive lyric lines.
    private static let dimOpacity = 0.3
    /// Half-width of the soft edge, as a fraction of the line height.
    private static let featherRatio = 0.35
    /// How long a letter takes to scale up once the edge reaches it.
    private static let letterGrowDuration: TimeInterval = 0.25

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let timing = run[Timing.self] else {
                    var dim = context
                    dim.opacity *= Self.dimOpacity
                    dim.draw(run)
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
        let travel = rect.width + 2 * feather
        let edge = rect.minX - feather + progress * travel
        var bright = context
        bright.opacity *= activeAmount
        let showsBright = progress > 0 && activeAmount > 0
        if showsBright {
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

        for letter in run {
            let bounds = letter.typographicBounds.rect
            // Once the edge reaches this letter's center it scales up over a
            // fixed short duration, rather than tracking the edge, so each
            // letter visibly pops to full size.
            let reachedAt = timing.start + span * (bounds.midX - (rect.minX - feather)) / travel
            let grow = min(max((time - reachedAt) / Self.letterGrowDuration, 0), 1)
            let eased = 1 - pow(1 - grow, 3)
            let scale = 1 + (letterScale - 1) * eased * activeAmount

            var dim = context
            Self.scale(&dim, by: scale, around: bounds)
            dim.opacity *= Self.dimOpacity
            dim.draw(letter)

            guard showsBright else { continue }
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
