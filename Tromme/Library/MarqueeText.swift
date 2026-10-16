import SwiftUI

/// Single-line text that scrolls horizontally, like Apple Music, only when it doesn't fit.
struct MarqueeText: View {
    let text: String
    var font: Font = .title3.bold()
    var color: Color = .white
    /// When false the text truncates with an ellipsis instead of scrolling.
    var scrolls: Bool = true

    private let gap: CGFloat = 40
    private let speed: CGFloat = 30

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var start = Date()

    private var overflows: Bool { textWidth > containerWidth && containerWidth > 0 }
    private var wantsScrolling: Bool { scrolls && overflows }

    /// The mode switch is driven by these instead of `wantsScrolling` directly, in steps of its
    /// own (see the `.task` below), so it's never interpolated as part of a layout slide such as
    /// opening lyrics or the queue.
    @State private var showsPlain = true
    @State private var showsScroller = false
    /// Set while the scroller glides back to its start before handing over to the plain title.
    @State private var returnOffset: CGFloat?

    private var isRunning: Bool { showsScroller && returnOffset == nil }

    // When it fits (or scrolling is off) the title is a plain truncating Text laid out exactly like
    // the artist line, so it slides with the layout the same way. While scrolling, a natural-width
    // copy is drawn on top, offset by the clock. The copy sits in an overlay so it never affects
    // layout: if it did, its wider size could change the measured container width, flip scrolling
    // off, and loop forever (a frozen UI for titles right at the fit threshold). It is always
    // present (transparent when unused) so it follows layout slides.
    //
    // At the switch both show the same text in the same place. Starting, the scroller appears fully
    // opaque and the plain title fades out beneath it, so nothing dims; stopping swaps at once.
    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(showsPlain ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .overlay(alignment: .leading) {
                // Only the scrolling copy is clipped and edge-faded. The plain title has no clip,
                // like the artist line, so nothing trails behind it while the layout slides.
                Color.clear
                    .overlay(alignment: .leading) {
                        TimelineView(.animation(paused: !isRunning)) { context in
                            HStack(spacing: gap) {
                                Text(text)
                                // Trailing copy that makes the loop seamless.
                                Text(text)
                            }
                            .font(font)
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize()
                            .offset(x: returnOffset ?? offset(at: context.date))
                        }
                    }
                    .clipped()
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.92),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    }
                    .opacity(showsScroller ? 1 : 0)
            }
            // Resolve the title's geometry as one unit, so it slides exactly in step with the
            // artist line instead of its inner text animating separately from its frame.
            .geometryGroup()
        .background(alignment: .leading) {
            // Natural width of the text, for the overflow check.
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    if textWidth != $0 { textWidth = $0 }
                }
        }
        .onChange(of: text) { start = Date() }
        .task(id: wantsScrolling) {
            if wantsScrolling {
                await startScrolling()
            } else {
                await stopScrolling()
            }
        }
    }

    /// Waits for the layout to settle (e.g. lyrics or the queue closing) before taking over, since
    /// the marquee holds still for its first few seconds anyway. The scroller appears at its start,
    /// exactly over the plain title, which then fades out beneath it.
    private func startScrolling() async {
        guard !isRunning else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        start = Date()
        returnOffset = nil
        showsScroller = true
        withAnimation(.easeOut(duration: 0.3)) { showsPlain = false }
    }

    /// Glides the scroller back to its start (or on to the trailing copy, if that's closer, which
    /// looks the same), then swaps straight to the plain title.
    private func stopScrolling() async {
        guard showsScroller else {
            showsPlain = true
            return
        }
        let distance = textWidth + gap
        let current = returnOffset ?? offset(at: .now)
        let target: CGFloat = current < -distance / 2 ? -distance : 0
        if current != target {
            returnOffset = current
            withAnimation(.easeInOut(duration: 0.5)) { returnOffset = target }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        // Swapped at once: fading would show the scroller's edge fade over the truncated title.
        showsPlain = true
        showsScroller = false
        returnOffset = nil
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = textWidth + gap
        let scroll = Double(distance / speed)
        let pauseSeconds = 4.0
        let t = (date.timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate)
            .truncatingRemainder(dividingBy: pauseSeconds + scroll)
        guard t > pauseSeconds else { return 0 }
        return -distance * CGFloat((t - pauseSeconds) / scroll)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        MarqueeText(text: "A Very Long Track Title That Will Not Fit On One Line")
        MarqueeText(text: "Short")
    }
    .padding()
    .frame(width: 220)
    .background(.black)
}
