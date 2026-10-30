import SwiftUI

struct ArtistSidePanelView: View {
    let artist: PlexMetadata
    let width: CGFloat
    let backdropColor: Color
    var hasBio = false
    var onInfo: (() -> Void)?
    var onChangePhoto: (() -> Void)?
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    private let photoCornerRadius: CGFloat = 20

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if artist.thumb != nil {
                    ArtworkView(
                        thumbPath: artist.thumb,
                        size: width,
                        cornerRadius: photoCornerRadius,
                        minimumTranscodePx: 1000
                    )
                    .artworkBorder(cornerRadius: photoCornerRadius)
                    .changeArtworkOnLongPress(isEnabled: onChangePhoto != nil) { onChangePhoto?() }
                }

                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)

                ArtistHeroControlsView(
                    backdropColor: backdropColor,
                    hasBio: hasBio,
                    onInfo: onInfo,
                    onPlay: onPlay,
                    onShuffle: onShuffle
                )
            }
            .frame(width: width)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }
}

#if DEBUG
#Preview {
    ArtistSidePanelView(
        artist: DevelopmentMockData.previewArtist,
        width: 420,
        backdropColor: .indigo,
        hasBio: true
    )
    .background(Color.indigo)
    .environment(\.colorScheme, .dark)
}
#endif
