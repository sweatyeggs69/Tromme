import SwiftUI

/// Artist photo drawn behind the list. Pinned to the top of the screen, zooms on overscroll,
/// parallaxes at half speed and blurs out as the page scrolls.
struct ArtistHeroPhotoView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(NetworkStatus.self) private var network

    let artist: PlexMetadata
    let heroHeight: CGFloat
    let backdropColor: Color
    let scrollOffset: CGFloat
    @Binding var isHidden: Bool

    @State private var image: UIImage?

    /// Height of the fade/blur band. It is anchored to the bottom edge of the hero row (where the
    /// artist name and buttons sit), not to the photo, so it stays behind them while the photo
    /// parallaxes.
    private let bandHeight: CGFloat = 190

    var body: some View {
        GeometryReader { geo in
            let stretch = max(-scrollOffset, 0)
            let scrolled = max(scrollOffset, 0)
            // Photo scrolls at half speed so the title and controls glide over it.
            let parallax = scrolled * 0.5
            // Photo blurs out as the title nears the top safe area.
            let blurProgress = min(max((scrolled - heroHeight * 0.4) / (heroHeight * 0.35), 0), 1)
            let scrollBlur = blurProgress * 30
            // On-screen bottom edge of the hero row.
            let rowBottom = max(heroHeight - scrollOffset, 0)
            let width = geo.size.width

            if !isHidden {
                ZStack(alignment: .top) {
                    transformedPhoto(width: width, blur: scrollBlur, stretch: stretch, parallax: parallax)

                    // Progressive blur behind the title and controls.
                    transformedPhoto(width: width, blur: 30, stretch: stretch, parallax: parallax)
                        .mask(alignment: .top) {
                            band(rowBottom: rowBottom) {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .black.opacity(0.7), location: 0.35),
                                        .init(color: .black, location: 0.6)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                        }

                    // Melt into the backdrop color.
                    band(rowBottom: rowBottom) {
                        LinearGradient(
                            stops: [
                                .init(color: backdropColor.opacity(0), location: 0),
                                .init(color: backdropColor.opacity(0.3), location: 0.3),
                                .init(color: backdropColor.opacity(0.7), location: 0.6),
                                .init(color: backdropColor.opacity(0.92), location: 0.85),
                                .init(color: backdropColor, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .frame(width: width, height: geo.size.height, alignment: .top)
                // Never paint below the hero row's current bottom edge.
                .mask(alignment: .top) {
                    Rectangle()
                        .frame(height: rowBottom)
                }
            }
        }
        .task(id: artist.thumb) {
            await loadImage()
        }
    }

    /// Places `content` in a band of `bandHeight` that ends at the hero row's bottom edge.
    private func band(rowBottom: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(height: bandHeight)
            .offset(y: rowBottom - bandHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func transformedPhoto(width: CGFloat, blur: CGFloat, stretch: CGFloat, parallax: CGFloat) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .frame(width: width, height: heroHeight, alignment: .top)
        .blur(radius: blur, opaque: true)
        .clipped()
        // Zoom from the first point of overscroll, pinned to the top edge.
        .scaleEffect(1 + stretch / max(heroHeight, 1), anchor: .top)
        .offset(y: -parallax)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func loadImage() async {
        guard let server = serverConnection.currentServer else {
            image = nil
            isHidden = true
            return
        }
        let artworkPath = artist.thumb
        guard let url = client.artworkURL(server: server, path: artworkPath, width: 1000, height: 1000) else {
            image = nil
            isHidden = !network.isConnected
            return
        }
        let resolvedImage = await ImageCache.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = resolvedImage?.squareCropped()
        isHidden = image == nil && !network.isConnected
    }
}

private extension UIImage {
    func squareCropped() -> UIImage {
        let side = min(size.width, size.height)
        guard side < max(size.width, size.height) else { return self }
        let origin = CGPoint(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage, let cropped = cgImage.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}
