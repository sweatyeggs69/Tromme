import Foundation
import SwiftUI

struct AlbumRecommendationGridView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedAlbum: PlexMetadata?

    let title: String
    let albums: [PlexMetadata]

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: AppStyle.ArtistDetailAlbumGrid.itemSpacing), count: count)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: AppStyle.ArtistDetailAlbumGrid.rowSpacing) {
                ForEach(albums) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        VStack(alignment: .leading, spacing: AppStyle.ArtistDetailAlbumGrid.itemContentSpacing) {
                            GeometryReader { geo in
                                ArtworkView(
                                    thumbPath: album.thumb,
                                    size: geo.size.width,
                                    cornerRadius: AppStyle.ArtistDetailAlbumGrid.artworkCornerRadius
                                )
                            }
                            .aspectRatio(1, contentMode: .fit)

                            Text(album.title)
                                .appItemTitleStyle()

                            Text(album.parentTitle ?? album.releaseYear)
                                .appItemSubtitleStyle()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            .padding(.vertical, AppStyle.AlbumLayout.gridVerticalPadding)
        }
        .navigationTitle(title)
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
    }
}
