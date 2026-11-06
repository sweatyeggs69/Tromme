import SwiftUI

struct HomeHubSectionView<Menu: View>: View {
    let hub: Hub
    @ViewBuilder let albumMenu: (PlexMetadata) -> Menu

    var body: some View {
        let items = hub.metadata ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
                Text(HomeHubConfig.title(for: hub))
                    .appSectionTitleStyle()

                switch HomeHubConfig.rowType(of: hub) {
                case "track":
                    HorizontalTrackGrid(tracks: items)
                case "artist":
                    HorizontalArtistRow(artists: items)
                default:
                    HorizontalAlbumRow(albums: items, menu: albumMenu)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HomeHubSectionView(hub: Hub(hubIdentifier: "preview", title: "Preview", type: "album", size: 0, metadata: [])) { _ in }
    }
}
