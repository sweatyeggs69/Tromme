import SwiftUI

struct ArtistHeroHeaderView: View {
    let artist: PlexMetadata
    let heroHeight: CGFloat
    let backdropColor: Color
    var isHidden: Bool
    var hasBio = false
    var onInfo: (() -> Void)?
    var onChangePhoto: (() -> Void)?
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    var body: some View {
        content
            .changeArtworkOnLongPress(isEnabled: onChangePhoto != nil) { onChangePhoto?() }
    }

    private var controls: some View {
        ArtistHeroControlsView(
            backdropColor: backdropColor,
            hasBio: hasBio,
            onInfo: onInfo,
            onPlay: onPlay,
            onShuffle: onShuffle
        )
    }

    @ViewBuilder
    private var content: some View {
        if isHidden {
            VStack(spacing: 20) {
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                controls
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 130)
            .padding(.bottom, 12)
        } else {
            // Title and controls sit on the bottom edge of the row and scroll with it; the
            // photo behind them is drawn by ArtistHeroPhotoView.
            VStack(spacing: 20) {
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.white)
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
}
