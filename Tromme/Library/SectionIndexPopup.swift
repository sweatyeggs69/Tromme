import SwiftUI

struct SectionIndexPopup: View {
    let title: String?

    var body: some View {
        ZStack {
            if let title {
                Text(title)
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 96, height: 96)
                    .glassEffect(.clear, in: .rect(cornerRadius: 24))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: title)
        .allowsHitTesting(false)
    }
}

#Preview {
    SectionIndexPopup(title: "M")
}
