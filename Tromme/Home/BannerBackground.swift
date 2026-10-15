import SwiftUI

struct BannerBackground: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @AppStorage("featuredBannerSize") private var featuredBannerSizeRaw = "large"

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
        // Phase 1: show any cached image immediately while the full-size download runs.
        let hasMemoryImage = ImageCache.shared.memoryCachedImage(for: url, targetPixelSize: px) != nil
        if image == nil && !hasMemoryImage {
            if let quick = await ImageCache.shared.anyCachedImage(for: url, targetPixelSize: px) {
                guard !Task.isCancelled else { return }
                image = quick
            }
        }
        // Phase 2: fetch proper size, keep phase 1 image if network fails.
        let resolved = await ImageCache.shared.image(for: url, targetPixelSize: px)
        guard !Task.isCancelled else { return }
        image = resolved ?? image
    }
}
