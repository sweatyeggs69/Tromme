import SwiftUI

/// One of the server's Recommended hubs. The set of hubs is dynamic, so rows are chosen by item type:
/// songs get the track grid, albums and artists get cards.
struct HomeHubSectionView: View {
    let hub: Hub

    /// The hub's items this view can show: all songs, or else the albums and artists.
    static func displayableItems(in hub: Hub) -> [PlexMetadata] {
        let items = hub.metadata ?? []
        let tracks = items.filter { $0.type == "track" }
        if tracks.count == items.count { return tracks }
        return items.filter { $0.type == "album" || $0.type == "artist" }
    }

    private var items: [PlexMetadata] { Self.displayableItems(in: hub) }
    private var isTrackRow: Bool { items.allSatisfy { $0.type == "track" } }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Text(hub.title ?? "")
                .appSectionTitleStyle()
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)

            if isTrackRow {
                HorizontalTrackGrid(tracks: items)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(
                                        thumbPath: item.thumb,
                                        size: AppStyle.Artwork.card,
                                        cornerRadius: item.type == "artist" ? AppStyle.Artwork.card / 2 : AppStyle.Radius.card
                                    )
                                    Text(item.title)
                                        .appItemTitleStyle()
                                    Text(item.type == "artist" ? "" : (item.parentTitle ?? ""))
                                        .appItemSubtitleStyle()
                                }
                                .frame(width: AppStyle.Artwork.card, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeHubSectionView(hub: Hub(
            hubIdentifier: "music.preview",
            title: "Recently Added",
            type: "album",
            size: nil,
            metadata: DevelopmentMockData.recentAlbums
        ))
    }
}
#endif
