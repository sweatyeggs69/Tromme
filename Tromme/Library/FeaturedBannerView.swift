import SwiftUI

struct FeaturedBannerView: View {
    let album: PlexMetadata

    private let bannerHeight: CGFloat = 180

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                BannerBackground(
                    thumbPath: album.art ?? album.parentThumb ?? album.thumb,
                    size: CGSize(width: geo.size.width, height: bannerHeight)
                )
                .frame(width: geo.size.width, height: bannerHeight)
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.75), location: 0),
                        .init(color: .black.opacity(0.35), location: 0.5),
                        .init(color: .clear, location: 0.78),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title)
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.4), radius: 2)

                        if let artist = album.parentTitle {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ArtworkView(
                        thumbPath: album.thumb,
                        size: 130,
                        cornerRadius: AppStyle.Radius.card
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.Radius.card)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 12, x: 0, y: 4)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(height: bannerHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.card))
    }
}

private struct BannerBackground: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale

    let thumbPath: String?
    let size: CGSize

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: thumbPath) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let thumbPath, let server = serverConnection.currentServer else {
            image = nil
            return
        }
        let px = ArtworkView.recommendedTranscodeSize(
            pointSize: max(size.width, size.height),
            displayScale: displayScale
        )
        guard let url = client.artworkURL(server: server, path: thumbPath, width: px, height: px) else {
            image = nil
            return
        }
        image = await ImageCache.shared.image(for: url, targetPixelSize: px)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FeaturedBannerView(album: DevelopmentMockData.recentAlbums[0])
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
    }
}
#endif
