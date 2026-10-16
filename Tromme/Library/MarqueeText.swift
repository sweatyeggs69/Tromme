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
    /// Follows `wantsScrolling`, but is switched in its own non-animated update. The switch
    /// usually happens inside the parent's layout animation (opening lyrics or the queue), and
    /// interpolating natural-width scrolling text into truncated text jumps around; updating
    /// it separately snaps the mode while the title keeps sliding with the layout.
    @State private var isScrolling = false

    // When it fits (or scrolling is off) the title is a plain truncating Text laid out exactly like
    // the artist line, so it slides with the layout the same way. Only while scrolling is that
    // Text hidden and a natural-width copy drawn on top, offset by the clock. The copy sits in an
    // overlay so it never affects layout: if it did, its wider size could change the measured
    // container width, flip scrolling off, and loop forever (a frozen UI for titles right at
    // the fit threshold). The two are swapped in a non-animated update (see `isScrolling`).
    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isScrolling ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .overlay(alignment: .leading) {
                if isScrolling {
                    TimelineView(.animation) { context in
                        HStack(spacing: gap) {
                            Text(text)
                            // Trailing copy that makes the loop seamless.
                            Text(text)
                        }
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: offset(at: context.date))
                    }
                }
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
        .onChange(of: wantsScrolling, initial: true) { _, wants in
            guard wants != isScrolling else { return }
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                isScrolling = wants
                start = Date()
            }
        }
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
