import SwiftUI

/// Draws a word-synced lyric line the way Apple Music does: each word starts
/// dimmed and a soft bright edge wipes across it as it's sung. Words are
/// tagged with `Timing` so the line still wraps as ordinary text.
///
/// `activeAmount` animates between 0 (inactive) and 1 (active), so when the
/// line hands off to the next one the highlight fades out instead of
/// snapping off.
struct WordWipeTextRenderer: TextRenderer {
    struct Timing: TextAttribute {
        let start: TimeInterval
        let end: TimeInterval
    }

    var time: TimeInterval
    var activeAmount: Double

    var animatableData: Double {
        get { activeAmount }
        set { activeAmount = newValue }
    }

    /// Dimmed text, matching inactive lyric lines. Word-synced lines own their
    /// whole opacity (the line itself stays fully opaque), so a line becoming
    /// active only fades the wipe overlay in and out and never has to
    /// coordinate two animations of its base text.
    private static let dimOpacity = 0.3
    /// Half-width of the soft edge, as a fraction of the line height.
    private static let featherRatio = 0.35

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

        var base = context
        base.opacity *= Self.dimOpacity
        base.draw(run)
        if showsBright { bright.draw(run) }
    }
}
