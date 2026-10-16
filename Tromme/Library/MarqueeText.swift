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
    private var isScrolling: Bool { scrolls && overflows }

    // One Text serves both modes: it truncates in its container, or (when scrolling) takes its
    // natural width and is offset by the clock. Nothing is swapped or faded between modes, so
    // the title slides with the layout exactly like the artist text.
    //
    // The visible text sits in an overlay so it never affects layout. A hidden, always-truncating
    // copy sizes the view instead; otherwise switching to the natural width while scrolling can
    // change the measured container width, which flips scrolling back off, and so on forever
    // (a frozen UI for titles right at the fit threshold).
    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .overlay(alignment: .leading) {
                TimelineView(.animation(paused: !isScrolling)) { context in
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: isScrolling, vertical: false)
                        .overlay(alignment: .leading) {
                            // Trailing copy that makes the loop seamless; never animated in or out.
                            Text(text)
                                .font(font)
                                .foregroundStyle(color)
                                .lineLimit(1)
                                .fixedSize()
                                .offset(x: textWidth + gap)
                                .opacity(isScrolling ? 1 : 0)
                                .transaction { $0.animation = nil }
                        }
                        .offset(x: offset(at: context.date))
                }
                // Switching between scrolling and truncating (e.g. opening lyrics or the queue)
                // happens inside the parent's layout animation. Interpolating the jump from the
                // natural-width, offset text to the truncated one looks glitchy, so it snaps
                // while the surrounding layout still animates.
                .transaction(value: isScrolling) { $0.animation = nil }
            }
        .clipped()
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: isScrolling ? 0.92 : 1),
                    .init(color: .black.opacity(isScrolling ? 0 : 1), location: 1)
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .transaction(value: isScrolling) { $0.animation = nil }
        }
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
        .onChange(of: isScrolling) { start = Date() }
    }

    private func offset(at date: Date) -> CGFloat {
        guard isScrolling else { return 0 }
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
