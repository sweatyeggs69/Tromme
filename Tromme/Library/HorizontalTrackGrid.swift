import SwiftUI

struct HorizontalTrackGrid: View {
    let tracks: [PlexMetadata]
    var rowCount: Int = 2
    var showArtist: Bool = true
    var showFavoriteStar: Bool = true
    var subtitleProvider: ((PlexMetadata) -> String?)? = nil

    private var gridHeight: CGFloat {
        CGFloat(rowCount) * AppStyle.TrackGrid.artworkSize
            + CGFloat(rowCount - 1) * AppStyle.TrackGrid.rowSpacing
    }

    var body: some View {
        GeometryReader { proxy in
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
                            showFavoriteStar: showFavoriteStar,
                            isCompact: true,
                            titleFont: AppStyle.Typography.itemTitle,
                            artistFont: AppStyle.Typography.itemSubtitle
                        )
                        .padding(.trailing, 16)
                        .frame(width: AppStyle.TrackGrid.itemWidth, alignment: .leading)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, AppStyle.Spacing.pageHorizontal)
                .padding(.trailing, max(
                    AppStyle.Spacing.pageHorizontal,
                    proxy.size.width - AppStyle.TrackGrid.itemWidth - AppStyle.Spacing.pageHorizontal
                ))
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(height: gridHeight)
    }
}

#Preview {
    HorizontalTrackGrid(tracks: [])
}
