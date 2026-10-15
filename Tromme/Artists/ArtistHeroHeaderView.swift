import SwiftUI

struct ArtistHeroHeaderView: View {
    let artist: PlexMetadata
    let heroHeight: CGFloat
    let backdropColor: Color
    var isHidden: Bool
    var hasBio = false
    var onInfo: (() -> Void)?
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    var body: some View {
        if isHidden {
            VStack(spacing: 20) {
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(backdropColor.contrastForeground)
                    .multilineTextAlignment(.center)
                controls
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.bottom, 12)
        } else {
            // Title and controls sit on the bottom edge of the row and scroll with it; the
            // photo behind them is drawn by ArtistHeroPhotoView.
            VStack(spacing: 20) {
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(backdropColor.contrastForeground)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppStyle.Spacing.pageHorizontal)

                controls
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight, alignment: .bottom)
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button {
                onInfo?()
            } label: {
                Image(systemName: "info")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(backdropColor.contrastForeground)
                    .frame(width: 52, height: 52)
                    .background(backdropColor.contrastCircleBackground, in: Circle())
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
                    .background(backdropColor.contrastForeground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play")

            Button {
                onShuffle?()
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(backdropColor.contrastForeground)
                    .frame(width: 52, height: 52)
                    .background(backdropColor.contrastCircleBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}
