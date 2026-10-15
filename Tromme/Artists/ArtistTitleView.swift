import SwiftUI

/// The artist's name on the detail page: their fanart.tv logo once it's available (from the
/// on-disk cache after the first visit), otherwise the name as text.
struct ArtistTitleView: View {
    let artist: PlexMetadata

    @State private var logo: UIImage?

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 96)
                    .accessibilityLabel(artist.title)
            } else {
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
        }
        .transition(.opacity)
        .task(id: artist.ratingKey + (artist.musicBrainzArtistID ?? "")) {
            guard let url = await ArtistLogoService.logoURL(for: artist),
                  let image = await ImageCache.shared.image(for: url) else { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { logo = image }
        }
    }
}

#Preview {
    ArtistTitleView(artist: PlexMetadata(ratingKey: "1", title: "Green Day", type: "artist"))
        .padding()
        .background(Color.black)
}
