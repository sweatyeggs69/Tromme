import SwiftUI

struct AllAlbumsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale

    @State private var albums: [PlexMetadata]
    @State private var isLoading: Bool
    @AppStorage("allAlbumsViewMode") private var viewMode: AlbumViewMode = .grid

    private let previewAlbums: [PlexMetadata]?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: AppStyle.ArtistDetailAlbumGrid.itemSpacing), count: count)
    }

    init(previewAlbums: [PlexMetadata]? = nil) {
        self.previewAlbums = previewAlbums
        _albums = State(initialValue: previewAlbums ?? [])
        _isLoading = State(initialValue: previewAlbums == nil)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                contentView
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewMode = viewMode == .grid ? .list : .grid
                } label: {
                    Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(viewMode == .grid ? "Show as list" : "Show as grid")
            }
        }
        .task {
            guard previewAlbums == nil else { return }
            await loadAlbums()
        }
        .task(id: artworkPrefetchKey) {
            await prefetchVisibleArtwork()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .grid:
            ScrollView {
                LazyVGrid(columns: columns, spacing: AppStyle.ArtistDetailAlbumGrid.rowSpacing) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
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

                                Text(album.parentTitle ?? "")
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

        case .list:
            List(albums) { album in
                NavigationLink(value: album) {
                    HStack(spacing: 10) {
                        ArtworkView(
                            thumbPath: album.thumb,
                            size: AppStyle.AlbumLayout.listArtworkSize,
                            cornerRadius: AppStyle.AlbumLayout.listArtworkCornerRadius
                        )

                        VStack(alignment: .leading, spacing: AppStyle.AlbumLayout.listTextSpacing) {
                            Text(album.title)
                                .appItemTitleStyle()

                            Text(album.parentTitle ?? "")
                                .appItemSubtitleStyle()
                        }
                    }
                    .padding(.vertical, AppStyle.AlbumLayout.listRowVerticalPadding)
                }
                .buttonStyle(.plain)
                .listRowInsets(AppStyle.AlbumLayout.listRowInsets)
            }
            .listStyle(.plain)
        }
    }

    private var artworkPrefetchKey: String {
        "\(viewMode.rawValue)|\(albums.count)"
    }

    private func loadAlbums() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        do {
            albums = try await client.cachedAlbums(server: server, sectionId: sectionId)
            albums.sort { ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title) }
        } catch {
            // Handle error
        }
        isLoading = false
    }

    private func prefetchVisibleArtwork() async {
        guard !isLoading, let server = serverConnection.currentServer else { return }
        let prefetchCount = viewMode == .grid ? 80 : 60
        let pointSize: CGFloat = if viewMode == .grid {
            horizontalSizeClass == .regular ? 220 : 180
        } else {
            AppStyle.AlbumLayout.listArtworkSize
        }
        let pixelSize = ArtworkView.recommendedTranscodeSize(pointSize: pointSize, displayScale: displayScale)
        let urls = albums.prefix(prefetchCount).compactMap { album in
            client.artworkURL(server: server, path: album.thumb, width: pixelSize, height: pixelSize)
        }
        await ImageCache.shared.prefetch(urls: urls, targetPixelSize: pixelSize, maxConcurrent: 4)
    }
}

private enum AlbumViewMode: String {
    case grid
    case list
}

#if DEBUG
#Preview {
    NavigationStack {
        AllAlbumsView(previewAlbums: DevelopmentMockData.allAlbums)
    }
}
#endif
