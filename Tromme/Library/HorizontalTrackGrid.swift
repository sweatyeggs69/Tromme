import SwiftUI

struct HorizontalTrackGrid: View {
    let tracks: [PlexMetadata]
    var rowCount: Int = 2
    var showArtist: Bool = true
    var subtitleProvider: ((PlexMetadata) -> String?)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(
                rows: Array(repeating: GridItem(.fixed(AppStyle.TrackGrid.artworkSize), spacing: AppStyle.TrackGrid.rowSpacing), count: rowCount),
                spacing: AppStyle.Spacing.listItemGap
            ) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRowView(
                        track: track,
                        tracks: tracks,
                        index: index,
                        showArtwork: true,
                        showArtist: showArtist,
                        subtitle: subtitleProvider?(track),
                        showTrackNumber: false,
                        artworkSize: AppStyle.TrackGrid.artworkSize,
                        showsMenu: false,
                        isCompact: true,
                        titleFont: AppStyle.Typography.itemTitle,
                        artistFont: AppStyle.Typography.itemSubtitle
                    )
                    .frame(width: AppStyle.TrackGrid.itemWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
        }
    }
}

#Preview {
    HorizontalTrackGrid(tracks: [])
}
