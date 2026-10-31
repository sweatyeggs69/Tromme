import SwiftUI

struct AutoMixGlyph: View {
    @ScaledMetric(relativeTo: .callout) private var ring: CGFloat = 14

    var body: some View {
        HStack(spacing: -ring * 0.4) {
            Circle().stroke(lineWidth: ring * 0.13)
            Circle().stroke(lineWidth: ring * 0.13)
        }
        .frame(width: ring * 1.6, height: ring)
        .accessibilityLabel("Auto Mix")
    }
}

#Preview {
    AutoMixGlyph()
        .foregroundStyle(.white)
        .padding()
        .background(.black)
}
