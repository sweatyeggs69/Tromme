import SwiftUI

struct AllAlbumsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @Environment(AudioPlayerService.self) private var player

    @State private var albums: [PlexMetadata]
    @State private var isLoading: Bool
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @AppStorage("allAlbumsViewMode") private var viewMode: AlbumViewMode = .grid
    @State private var addToPlaylistItemKeys: [String] = []
    @State private var showingAddToPlaylistSheet = false
    @State private var selectedAlbum: PlexMetadata?

    private let previewAlbums: [PlexMetadata]?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: AppStyle.ArtistDetailAlbumGrid.itemSpacing), count: count)
    }

    private var filteredAlbums: [PlexMetadata] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return albums }
        return albums.filter { album in
            album.title.localizedCaseInsensitiveContains(query)
            || (album.parentTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var albumSections: [(title: String, items: [PlexMetadata])] {
        alphabetSections(for: filteredAlbums) { album in
            album.titleSort ?? album.title
        }
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
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Filter albums"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewMode = viewMode == .grid ? .list : .grid
                } label: {
                    Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                }
                .tint(.primary)
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
        .onDisappear {
            searchText = ""
            isSearchPresented = false
        }
        .sheet(isPresented: $showingAddToPlaylistSheet) {
            AddToPlaylistSheet(itemRatingKeys: addToPlaylistItemKeys)
        }
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .grid:
            if filteredAlbums.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(albumSections, id: \.title) { section in
                        Section(section.title) {
                            LazyVGrid(columns: columns, spacing: AppStyle.ArtistDetailAlbumGrid.rowSpacing) {
                                ForEach(section.items) { album in
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

                                            Text(album.parentTitle ?? "")
                                                .appItemSubtitleStyle()
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        albumContextMenu(for: album)
                                    }
                                }
                            }
                            .padding(.bottom, 12)
                            .listRowInsets(EdgeInsets(top: 0, leading: AppStyle.Spacing.pageHorizontal, bottom: 0, trailing: AppStyle.Spacing.pageHorizontal))
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.plain)
            }

        case .list:
            if filteredAlbums.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(albumSections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.items) { album in
                                Button {
                                    selectedAlbum = album
                                } label: {
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
                                .contextMenu {
                                    albumContextMenu(for: album)
                                }
                                .listRowInsets(AppStyle.AlbumLayout.listRowInsets)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var artworkPrefetchKey: String {
        "\(viewMode.rawValue)|\(filteredAlbums.count)|\(searchText)"
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
        // Skip aggressive prefetching on metered networks or in Low Power Mode —
        // images will still load lazily as the user scrolls.
        guard !NetworkStatus.shared.isExpensive,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let prefetchCount = viewMode == .grid ? 80 : 60
        let pointSize: CGFloat = if viewMode == .grid {
            horizontalSizeClass == .regular ? 220 : 180
        } else {
            AppStyle.AlbumLayout.listArtworkSize
        }
        let pixelSize = ArtworkView.recommendedTranscodeSize(pointSize: pointSize, displayScale: displayScale)
        let urls = filteredAlbums.prefix(prefetchCount).compactMap { album in
            client.artworkURL(server: server, path: album.thumb, width: pixelSize, height: pixelSize)
        }
        await ImageCache.shared.prefetch(urls: urls, targetPixelSize: pixelSize, maxConcurrent: 4)
    }

    @ViewBuilder
    private func albumContextMenu(for album: PlexMetadata) -> some View {
        Button("Play Next", systemImage: "text.insert") {
            Task { await queueAlbumNext(album) }
        }
        Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
            Task { await queueAlbumLast(album) }
        }
        Button("Add to Playlist", systemImage: "text.badge.plus") {
            Task { await presentAddAlbumToPlaylist(album) }
        }
    }

    @MainActor
    private func queueAlbumNext(_ album: PlexMetadata) async {
        guard let server = serverConnection.currentServer else { return }
        guard let tracks = try? await client.cachedChildren(server: server, ratingKey: album.ratingKey), !tracks.isEmpty else { return }
        for track in tracks.reversed() {
            player.addToQueue(track)
        }
    }

    @MainActor
    private func queueAlbumLast(_ album: PlexMetadata) async {
        guard let server = serverConnection.currentServer else { return }
        guard let tracks = try? await client.cachedChildren(server: server, ratingKey: album.ratingKey), !tracks.isEmpty else { return }
        for track in tracks {
            player.addToEndOfQueue(track)
        }
    }

    @MainActor
    private func presentAddAlbumToPlaylist(_ album: PlexMetadata) async {
        guard let server = serverConnection.currentServer else { return }
        guard let tracks = try? await client.cachedChildren(server: server, ratingKey: album.ratingKey), !tracks.isEmpty else { return }
        addToPlaylistItemKeys = tracks.map(\.ratingKey)
        showingAddToPlaylistSheet = true
    }

    private func alphabetSections(
        for items: [PlexMetadata],
        sortKey: (PlexMetadata) -> String
    ) -> [(title: String, items: [PlexMetadata])] {
        var sections: [(title: String, items: [PlexMetadata])] = []

        for item in items {
            let title = alphabetSectionTitle(for: sortKey(item))
            if let index = sections.firstIndex(where: { $0.title == title }) {
                sections[index].items.append(item)
            } else {
                sections.append((title: title, items: [item]))
            }
        }

        return sections
    }

    private func alphabetSectionTitle(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let letter = String(first).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
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
    .environment(AudioPlayerService())
}
#endif
