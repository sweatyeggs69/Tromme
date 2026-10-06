import SwiftUI

/// Draws a word-synced lyric line the way Apple Music does: each word starts
/// dimmed, a soft bright edge wipes across it as it's sung, and it grows
/// slightly once it's reached. Words are tagged with `Timing` so the line still
/// wraps as ordinary text.
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

        var context = context
        // Ease the growth so it lands as the wipe finishes.
        let scale = 1 + (Self.sungScale - 1) * (1 - pow(1 - progress, 3))
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.midX, y: -rect.midY)

        var dim = context
        dim.opacity *= Self.dimOpacity
        dim.draw(run)

        guard progress > 0 else { return }
        let feather = rect.height * Self.featherRatio
        // Travels from fully before the word to fully past it, so the soft
        // edge enters and leaves cleanly.
        let edge = rect.minX - feather + progress * (rect.width + 2 * feather)
        var bright = context
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
        bright.draw(run)
    }
}
