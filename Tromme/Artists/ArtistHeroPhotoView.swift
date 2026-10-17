import SwiftUI

/// Artist photo drawn behind the list. Pinned to the top of the screen, zooms on overscroll,
/// parallaxes at half speed and blurs out as the page scrolls.
struct ArtistHeroPhotoView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    let artist: PlexMetadata
    let heroHeight: CGFloat
    let backdropColor: Color
    let scrollOffset: CGFloat
    @Binding var isHidden: Bool

    @State private var image: UIImage?

    /// Heights of the blur and color-fade bands, anchored to the bottom edge of the photo itself
    /// so they travel with the image (zoom, parallax) instead of the name and buttons.
    private let blurBandHeight: CGFloat = 145
    private let fadeBandHeight: CGFloat = 145

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
                photoWithFades(width: width, blur: scrollBlur)
                    // Zoom from the first point of overscroll, pinned to the top edge.
                    .scaleEffect(1 + stretch / max(heroHeight, 1), anchor: .top)
                    .offset(y: -parallax)
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

    /// The photo with its progressive blur and color fade baked into its bottom edge.
    private func photoWithFades(width: CGFloat, blur: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            photo(width: width, blur: blur)

            photo(width: width, blur: 30)
                .mask(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.8), location: 0.75),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: blurBandHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }

            LinearGradient(
                stops: [
                    .init(color: backdropColor.opacity(0), location: 0),
                    .init(color: backdropColor.opacity(0.8), location: 0.75),
                    .init(color: backdropColor, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: fadeBandHeight)
        }
        .frame(width: width, height: heroHeight)
        .clipped()
    }

    private func photo(width: CGFloat, blur: CGFloat) -> some View {
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
            isHidden = true
            return
        }
        let resolvedImage = await ImageCache.shared.image(for: url)
        guard !Task.isCancelled else { return }
        // Pick the page backdrop from this photo right away rather than waiting on the
        // backdrop's own smaller fetch, so the color arrives with the photo.
        if let resolvedImage {
            ArtworkColorCache.shared.resolveColor(for: artworkPath, from: resolvedImage, style: .artist)
        }
        image = resolvedImage?.squareCropped()
        isHidden = image == nil
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
