import SwiftUI

/// Shared capsule track used by the timeline and volume sliders so they stay identical.
struct SliderTrack: View {
    let progress: CGFloat
    let isDragging: Bool
    let width: CGFloat

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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isDragging)
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
