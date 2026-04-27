import SwiftUI

struct MiniLyricsLineView: View {
    let text: String

    var body: some View {
        ZStack {
            Text(text)
                .id(text)
                .font(.body.weight(.medium))
                .italic()
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.28), value: text)
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [.teal, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

        MiniLyricsLineView(text: "When the night has come and the land is dark")
            .padding(.horizontal, 24)
    }
    .preferredColorScheme(.dark)
}
