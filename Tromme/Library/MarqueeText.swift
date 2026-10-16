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

    // One stable view for both modes (a truncating base with the marquee as an overlay), so
    // switching modes never swaps the view and it slides with the layout like the artist text.
    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isScrolling ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .overlay(alignment: .leading) {
                if isScrolling {
                    // Offset comes from the clock, not an animated state, so animations from
                    // parent state changes can't interrupt or retarget the scroll.
                    TimelineView(.animation) { context in
                        HStack(spacing: gap) {
                            label
                            label
                        }
                        .offset(x: offset(at: context.date))
                        .fixedSize()
                    }
                }
            }
            .clipped()
            .mask {
                if isScrolling {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .onChange(of: text) { start = Date() }
            .onChange(of: isScrolling) { start = Date() }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
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
