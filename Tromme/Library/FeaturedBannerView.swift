import SwiftUI

private enum FeaturedBannerSize: String {
    case large, small, immersive
}

struct FeaturedCarouselView: View {
    let albums: [PlexMetadata]

    // 3 copies: [buffer | real | buffer] — 9 items for 3 albums.
    // Seamless looping: when position drifts into a buffer copy, silently
    // snap to the equivalent position in the middle copy (same content, no visible change).
    private var loopedAlbums: [PlexMetadata] { albums + albums + albums }

    @State private var scrollPosition: Int?
    @State private var isTimerScrolling = false
    @AppStorage("featuredBannerSize") private var featuredBannerSizeRaw = "immersive"

    private let horizontalPadding = AppStyle.Spacing.pageHorizontal
    private let itemSpacing: CGFloat = 12

    init(albums: [PlexMetadata]) {
        self.albums = albums
        _scrollPosition = State(initialValue: albums.count) // start in middle copy
    }

    private var bannerSize: FeaturedBannerSize { FeaturedBannerSize(rawValue: featuredBannerSizeRaw) ?? .large }

    private var bannerHeight: CGFloat {
        switch bannerSize {
        case .large: return 180
        case .small: return 90
        case .immersive: return 300
        }
    }

    private var effectiveHorizontalPadding: CGFloat { bannerSize == .immersive ? 0 : horizontalPadding }

    private func columnCount(for width: CGFloat) -> Int {
        guard bannerSize != .immersive else { return 1 }
        if width >= 1000 { return 3 }
        if width >= 600 { return 2 }
        return 1
    }

    var body: some View {
        GeometryReader { geo in
            let cols = columnCount(for: geo.size.width)
            let count = albums.count
            let totalSpacing = itemSpacing * CGFloat(cols - 1)
            let totalPadding = effectiveHorizontalPadding * 2
            let itemWidth = (geo.size.width - totalPadding - totalSpacing) / CGFloat(cols)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: itemSpacing) {
                    ForEach(Array(loopedAlbums.enumerated()), id: \.offset) { index, album in
                        NavigationLink(value: album) {
                            FeaturedBannerView(album: album)
                        }
                        .buttonStyle(.plain)
                        .frame(width: itemWidth)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollPosition)
            .contentMargins(.horizontal, effectiveHorizontalPadding, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollDisabled(cols >= count)
            .onChange(of: scrollPosition) { _, newPos in
                // User-initiated swipe hit a buffer copy — silently reset to middle copy.
                // Skip while the timer is mid-animation to avoid interrupting it.
                guard !isTimerScrolling, let pos = newPos else { return }
                if pos < count {
                    scrollPosition = pos + count
                } else if pos >= count * 2 {
                    scrollPosition = pos - count
                }
            }
            .task(id: cols) {
                guard count > cols else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(7))
                    guard !Task.isCancelled else { return }
                    let next = (scrollPosition ?? count) + 1
                    isTimerScrolling = true
                    withAnimation(.easeInOut(duration: 0.5)) {
                        scrollPosition = next
                    }
                    // Wait for animation to finish, then silently reset if we landed in the last buffer copy.
                    try? await Task.sleep(for: .milliseconds(600))
                    if let pos = scrollPosition, pos >= count * 2 {
                        scrollPosition = pos - count
                    }
                    isTimerScrolling = false
                }
            }
        }
        .frame(height: bannerHeight)
    }
}

struct FeaturedBannerView: View {
    let album: PlexMetadata

    @AppStorage("featuredBannerSize") private var featuredBannerSizeRaw = "immersive"
    private var bannerSize: FeaturedBannerSize { FeaturedBannerSize(rawValue: featuredBannerSizeRaw) ?? .large }

    private var bannerHeight: CGFloat {
        switch bannerSize {
        case .large: return 180
        case .small: return 90
        case .immersive: return 300
        }
    }

    private var artworkSize: CGFloat {
        switch bannerSize {
        case .large: return 130
        case .small: return 65
        case .immersive: return 150
        }
    }

    private var verticalPadding: CGFloat {
        switch bannerSize {
        case .large: return 12
        case .small: return 8
        case .immersive: return 20
        }
    }

    private var titleFont: Font {
        switch bannerSize {
        case .large: return .title3.bold()
        case .small: return .subheadline.bold()
        case .immersive: return .title2.bold()
        }
    }

    private var artistFont: Font {
        switch bannerSize {
        case .large: return .subheadline
        case .small: return .caption
        case .immersive: return .headline
        }
    }

    private var contentAlignment: Alignment {
        bannerSize == .immersive ? .bottomLeading : .leading
    }

    private var gradient: LinearGradient {
        if bannerSize == .immersive {
            return LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.8), location: 0),
                    .init(color: .black.opacity(0.4), location: 0.4),
                    .init(color: .clear, location: 0.7),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        } else {
            return LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.75), location: 0),
                    .init(color: .black.opacity(0.35), location: 0.5),
                    .init(color: .clear, location: 0.78),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: contentAlignment) {
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
        .clipShape(
            bannerSize == .immersive
                ? AnyShape(UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: AppStyle.Radius.card,
                    bottomTrailingRadius: AppStyle.Radius.card,
                    topTrailingRadius: 0
                ))
                : AnyShape(RoundedRectangle(cornerRadius: AppStyle.Radius.card))
        )
    }
}

private struct BannerBackground: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @AppStorage("featuredBannerSize") private var featuredBannerSizeRaw = "immersive"

    let thumbPath: String?
    let size: CGSize

    @State private var image: UIImage?

    private var bannerSize: FeaturedBannerSize { FeaturedBannerSize(rawValue: featuredBannerSizeRaw) ?? .large }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: bannerSize == .small ? .top : .center)
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
#Preview("Single Banner") {
    NavigationStack {
        FeaturedBannerView(album: DevelopmentMockData.recentAlbums[0])
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
    }
}

#Preview("Carousel") {
    NavigationStack {
        FeaturedCarouselView(albums: Array(DevelopmentMockData.recentAlbums.prefix(3)))
    }
}
#endif
