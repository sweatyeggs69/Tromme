import SwiftUI

struct SimilarArtistsGridView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedArtist: PlexMetadata?

    let artists: [PlexMetadata]

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 3
        return Array(repeating: GridItem(.flexible(), spacing: AppStyle.ArtistDetailAlbumGrid.itemSpacing), count: count)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: AppStyle.ArtistDetailAlbumGrid.rowSpacing) {
                ForEach(artists) { artist in
                    Button {
                        selectedArtist = artist
                    } label: {
                        VStack(alignment: .center, spacing: AppStyle.ArtistDetailAlbumGrid.itemContentSpacing) {
                            GeometryReader { geo in
                                ArtworkView(
                                    thumbPath: artist.thumb,
                                    size: geo.size.width,
                                    cornerRadius: geo.size.width / 2
                                )
                            }
                            .aspectRatio(1, contentMode: .fit)

                            Text(artist.title)
                                .appItemTitleStyle()
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            .padding(.vertical, AppStyle.AlbumLayout.gridVerticalPadding)
        }
        .navigationTitle("Similar Artists")
        .navigationDestination(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist)
        }
    }
}
