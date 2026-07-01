import SwiftUI

struct MarqueeText<Style: ShapeStyle>: View {
    let text: String
    let font: Font
    let foregroundStyle: Style

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offsetX: CGFloat = 0

    private let loopGap: CGFloat = 40
    private let pointsPerSecond: CGFloat = 35
    private let initialDelay: Double = 5
    private let cooldown: Double = 10

    private var overflows: Bool { containerWidth > 0 && textWidth > containerWidth }
    private var loopDistance: CGFloat { textWidth + loopGap }

    var body: some View {
        // Invisible text establishes correct line height and available width.
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in containerWidth = w }
                }
            }
            // Invisible overlay measures the text's natural (unconstrained) width.
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(0)
                    .background {
                        GeometryReader { textGeo in
                            Color.clear
                                .onAppear { textWidth = textGeo.size.width }
                                .onChange(of: textGeo.size.width) { _, w in textWidth = w }
                        }
                    }
            }
            // Visible content: two copies side-by-side when overflowing so the
            // loop resets seamlessly; a single copy otherwise.
            .overlay(alignment: .leading) {
                if overflows {
                    HStack(spacing: loopGap) {
                        Text(text).font(font).foregroundStyle(foregroundStyle)
                        Text(text).font(font).foregroundStyle(foregroundStyle)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: offsetX)
                } else {
                    Text(text)
                        .font(font)
                        .foregroundStyle(foregroundStyle)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflows ? 20 : 0)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: overflows)
            .task(id: "\(text)_\(overflows)_\(Int(containerWidth))") {
                offsetX = 0
                guard overflows else { return }
                await runScrollAnimation()
            }
            .onChange(of: text) { _, _ in
                textWidth = 0
                offsetX = 0
            }
    }

    private func runScrollAnimation() async {
        // Scroll one full text+gap cycle so the view lands back at its origin,
        // then hold for the cooldown before looping.
        let duration = loopDistance / pointsPerSecond
        do {
            try await Task.sleep(for: .seconds(initialDelay))
            while true {
                withAnimation(.linear(duration: duration)) {
                    offsetX = -loopDistance
                }
                // Wait for the animation to finish, then snap back to origin
                // (visually seamless — second copy is identical to the first).
                try await Task.sleep(for: .seconds(duration + 0.05))
                offsetX = 0
                try await Task.sleep(for: .seconds(cooldown))
            }
        } catch {
            offsetX = 0
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        MarqueeText(text: "Short Title", font: .title3.bold(), foregroundStyle: Color.white)
        MarqueeText(
            text: "A Very Long Song Title That Should Definitely Scroll Across The Screen",
            font: .title3.bold(),
            foregroundStyle: Color.white
        )
        MarqueeText(text: "Artist Name", font: .body, foregroundStyle: Color.white.opacity(0.6))
        MarqueeText(
            text: "A Very Long Artist Name That Also Needs To Scroll",
            font: .body,
            foregroundStyle: Color.white.opacity(0.6)
        )
    }
    .frame(width: 240)
    .padding(32)
    .background(.black)
}
