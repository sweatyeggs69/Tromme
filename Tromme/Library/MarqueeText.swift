import SwiftUI

/// Single-line text that scrolls horizontally, like Apple Music, only when it doesn't fit.
struct MarqueeText: View {
    let text: String
    var font: Font = .title3.bold()
    var color: Color = .white

    private let gap: CGFloat = 40
    private let speed: CGFloat = 30
    private let pause: Duration = .seconds(2)

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { textWidth > containerWidth && containerWidth > 0 }

    var body: some View {
        // Hidden text gives the row its height and the container its width.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: gap) {
                    label
                    if overflows { label }
                }
                .offset(x: offset)
                .fixedSize()
            }
            .clipped()
            .mask {
                if overflows {
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
            .task(id: "\(text)|\(textWidth)|\(containerWidth)") { await run() }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                if textWidth != $0 { textWidth = $0 }
            }
    }

    private func run() async {
        offset = 0
        guard overflows else { return }
        let distance = textWidth + gap
        let duration = Double(distance / speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: pause)
            if Task.isCancelled { return }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            if Task.isCancelled { return }
            offset = 0
        }
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
