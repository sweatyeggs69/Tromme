import SwiftUI

struct HorizontalAlbumRow<Menu: View>: View {
    let albums: [PlexMetadata]
    @ViewBuilder let menu: (PlexMetadata) -> Menu

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 4) {
                            ArtworkView(
                                thumbPath: album.thumb,
                                size: AppStyle.Artwork.card,
                                cornerRadius: AppStyle.Radius.card
                            )

                            Text(album.title)
                                .appItemTitleStyle()

                            Text(album.parentTitle ?? "")
                                .appItemSubtitleStyle()
                        }
                        .frame(width: AppStyle.Artwork.card, alignment: .topLeading)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        menu(album)
                    } preview: {
                        VStack(alignment: .leading, spacing: AppStyle.ArtistDetailAlbumGrid.itemContentSpacing) {
                            ArtworkView(
                                thumbPath: album.thumb,
                                size: 200,
                                cornerRadius: AppStyle.ArtistDetailAlbumGrid.artworkCornerRadius
                            )
                            .frame(width: 200, height: 200)
                            Text(album.title)
                                .appItemTitleStyle()
                            Text(album.parentTitle ?? "")
                                .appItemSubtitleStyle()
                        }
                        .frame(width: 200)
                        .padding()
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

#Preview {
    NavigationStack {
        HorizontalAlbumRow(albums: []) { _ in }
    }
}
