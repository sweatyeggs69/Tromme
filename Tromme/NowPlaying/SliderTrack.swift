import SwiftUI

struct SliderTrack: View {
    let progress: CGFloat
    let isDragging: Bool
    let width: CGFloat
    var isMixing = false

    var body: some View {
        let height: CGFloat = isDragging ? 16 : 7
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(height: height)
                .frame(maxHeight: .infinity)
            Capsule()
                .fill(.white)
                .frame(width: max(0, width * min(max(progress, 0), 1)), height: height)
                .frame(maxHeight: .infinity, alignment: .leading)
        }
        .overlay { if isMixing { shimmer(height: height) } }
        .shadow(color: .white.opacity(isMixing ? 0.55 : 0), radius: isMixing ? 9 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDragging)
        .animation(.easeInOut(duration: 0.5), value: isMixing)
    }

    private func shimmer(height: CGFloat) -> some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((time / 1.4).truncatingRemainder(dividingBy: 1))
            let pulse = 0.65 + 0.35 * sin(time * 4)
            LinearGradient(
                colors: [.clear, .white.opacity(0.9 * pulse), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width * 0.35, height: height)
            .offset(x: (phase * 1.35 - 0.35) * width - width / 2 + width * 0.175)
            .frame(width: width, height: height)
            .clipShape(Capsule())
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    VStack(spacing: 24) {
        SliderTrack(progress: 0.4, isDragging: false, width: 300).frame(height: 28)
        SliderTrack(progress: 0.4, isDragging: true, width: 300).frame(height: 28)
    }
    .padding()
    .background(.black)
}
