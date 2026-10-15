import SwiftUI

struct FeaturedBannerView: View {
    let album: PlexMetadata

    @AppStorage("featuredBannerSize") private var featuredBannerSizeRaw = "large"
    private var bannerSize: FeaturedBannerSize { FeaturedBannerSize(rawValue: featuredBannerSizeRaw) ?? .large }

    private var bannerHeight: CGFloat {
        switch bannerSize {
        case .large: return 180
        case .small: return 90
        }
    }

    private var artworkSize: CGFloat {
        switch bannerSize {
        case .large: return 130
        case .small: return 65
        }
    }

    private var verticalPadding: CGFloat {
        switch bannerSize {
        case .large: return 12
        case .small: return 8
        }
    }

    private var titleFont: Font {
        switch bannerSize {
        case .large: return .title3.bold()
        case .small: return .subheadline.bold()
        }
    }

    private var artistFont: Font {
        switch bannerSize {
        case .large: return .subheadline
        case .small: return .caption
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.75), location: 0),
                .init(color: .black.opacity(0.35), location: 0.5),
                .init(color: .clear, location: 0.78),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                BannerBackground(
                    thumbPath: album.art ?? album.parentThumb ?? album.thumb,
                    size: CGSize(width: geo.size.width, height: bannerHeight)
                )
                .frame(width: geo.size.width, height: bannerHeight)
                .clipped()

                gradient

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title)
                            .font(titleFont)
                            .foregroundStyle(.white)
                            .lineLimit(bannerSize == .small ? 1 : 2)
                            .shadow(color: .black.opacity(0.4), radius: 2)

                        if let artist = album.parentTitle {
                            Text(artist)
                                .font(artistFont)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ArtworkView(
                        thumbPath: album.thumb,
                        size: artworkSize,
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
                .padding(.vertical, verticalPadding)
            }
        }
        .frame(height: bannerHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.card))
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
