import SwiftUI

/// Apple Music style equalizer indicator for the playing row.
struct NowPlayingBarsView: View {
    var color: Color? = nil
    @State private var isAnimating = false
    /// Random heights and durations are computed once on appear and stable across re-renders.
    @State private var barHeights: [CGFloat] = [0.65, 0.85, 0.45, 0.75]
    @State private var barDurations: [Double] = [0.45, 0.38, 0.52, 0.41]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                    .frame(width: 3)
                    .scaleEffect(y: isAnimating ? barHeights[index] : 0.4, anchor: .bottom)
                    .animation(
                        .easeInOut(duration: barDurations[index])
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            barHeights = (0..<4).map { _ in CGFloat.random(in: 0.3...1.0) }
            barDurations = (0..<4).map { _ in Double.random(in: 0.3...0.6) }
            isAnimating = true
        }
        .onDisappear { isAnimating = false }
    }
}
