import SwiftUI

struct ArtistHeroControlsView: View {
    let backdropColor: Color
    var hasBio = false
    var onInfo: (() -> Void)?
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    var body: some View {
        HStack(spacing: 20) {
            Button {
                onInfo?()
            } label: {
                Image(systemName: "info")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(hasBio ? 1 : 0.4)
            .disabled(!hasBio)
            .accessibilityLabel("About")

            Button {
                onPlay?()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(backdropColor)
                    .frame(width: 62, height: 62)
                    .background(Color.white, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play")

            Button {
                onShuffle?()
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

#if DEBUG
#Preview {
    ArtistHeroControlsView(backdropColor: .indigo, hasBio: true)
        .background(Color.indigo)
}
#endif
