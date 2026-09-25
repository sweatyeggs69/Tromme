import SwiftUI

/// Shuffle / Play / add-menu button row shown under artwork on album and playlist detail
/// screens. Colors derive from `artworkColor` so the buttons read well against any artwork.
struct ArtworkActionButtonsRow<MenuContent: View>: View {
    let artworkColor: Color
    var isDisabled: Bool
    var bottomPadding: CGFloat = 20
    let onShuffle: () -> Void
    let onPlay: () -> Void
    @ViewBuilder var menuContent: () -> MenuContent

    private var iconForegroundColor: Color { artworkColor.contrastForeground }
    private var controlShadowColor: Color { artworkColor.contrastControlShadow }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onShuffle) {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(iconForegroundColor)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(artworkColor.contrastCircleBackground))
                    .shadow(color: controlShadowColor, radius: 6, y: -2)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.45 : 1.0)

            Button(action: onPlay) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(artworkColor)
                .padding(.horizontal, 50)
                .padding(.vertical, 14)
                .background(Capsule().fill(artworkColor.contrastForeground))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.45 : 1.0)

            Menu {
                menuContent()
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(iconForegroundColor)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(artworkColor.contrastCircleBackground))
                    .shadow(color: controlShadowColor, radius: 6, y: -2)
            }
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.45 : 1.0)
        }
        .padding(.top, 6)
        .padding(.bottom, bottomPadding)
    }
}

#Preview {
    ArtworkActionButtonsRow(
        artworkColor: .blue,
        isDisabled: false,
        onShuffle: {},
        onPlay: {},
        menuContent: {
            Button("Play Next", systemImage: "text.insert") {}
            Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {}
        }
    )
    .padding()
}
