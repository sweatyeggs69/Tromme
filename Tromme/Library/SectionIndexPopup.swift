import SwiftUI

struct SectionIndexPopup: View {
    let title: String?

    var body: some View {
        ZStack {
            if let title {
                Text(title)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 112, height: 112)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
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
