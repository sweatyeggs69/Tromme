import SwiftUI

struct FeaturedCarouselView: View {
    let albums: [PlexMetadata]

    @State private var scrollPosition: Int?
    @AppStorage("featuredBannerSize") private var featuredBannerSizeRaw = "large"

    private let horizontalPadding = AppStyle.Spacing.pageHorizontal
    private let itemSpacing: CGFloat = 12

    private var bannerSize: FeaturedBannerSize { FeaturedBannerSize(rawValue: featuredBannerSizeRaw) ?? .large }

    private var bannerHeight: CGFloat {
        switch bannerSize {
        case .large: return 180
        case .small: return 90
        }
    }

    private var effectiveHorizontalPadding: CGFloat { horizontalPadding }

    private func columnCount(for width: CGFloat) -> Int {
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
                    ForEach(Array(albums.enumerated()), id: \.offset) { index, album in
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
            .task(id: cols) {
                guard count > cols else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    let current = scrollPosition ?? 0
                    let next = current + 1 >= count ? 0 : current + 1
                    withAnimation(.easeInOut(duration: 0.5)) {
                        scrollPosition = next
                    }
                }
            }
        }
        .frame(height: bannerHeight)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FeaturedCarouselView(albums: Array(DevelopmentMockData.recentAlbums.prefix(5)))
    }
}
#endif
