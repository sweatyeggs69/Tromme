import SwiftUI

struct AllAlbumsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @Environment(AudioPlayerService.self) private var player
    @Environment(NetworkStatus.self) private var network
    @Environment(DownloadManager.self) private var downloadManager

    @State private var albums: [PlexMetadata]
    @State private var isLoading: Bool
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @AppStorage("allAlbumsViewMode") private var viewMode: AlbumViewMode = .grid
    @AppStorage("allAlbumsSortOrder") private var sortOrder: AlbumSortOrder = .titleAscending
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
        var result = query.isEmpty ? albums : albums.filter { album in
            album.title.localizedCaseInsensitiveContains(query)
            || (album.parentTitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
        switch sortOrder {
        case .titleAscending:
            result.sort {
                ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedAscending
            }
        case .titleDescending:
            result.sort {
                ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedDescending
            }
        case .artistAscending:
            result.sort {
                ($0.parentTitle ?? "").localizedStandardCompare($1.parentTitle ?? "") == .orderedAscending
            }
        case .artistDescending:
            result.sort {
                ($0.parentTitle ?? "").localizedStandardCompare($1.parentTitle ?? "") == .orderedDescending
            }
        case .yearOldest:
            result.sort {
                let y0 = releaseYearInt(for: $0), y1 = releaseYearInt(for: $1)
                if y0 != y1 { return y0 < y1 }
                return ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedAscending
            }
        case .yearNewest:
            result.sort {
                let y0 = releaseYearInt(for: $0), y1 = releaseYearInt(for: $1)
                if y0 != y1 { return y0 > y1 }
                return ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedAscending
            }
        case .dateAddedNewest:
            result.sort { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        case .dateAddedOldest:
            result.sort { ($0.addedAt ?? 0) < ($1.addedAt ?? 0) }
        }
        return result
    }

    private var albumSections: [(title: String, items: [PlexMetadata])] {
        switch sortOrder {
        case .artistAscending, .artistDescending:
            return alphabetSections(for: filteredAlbums) { $0.parentTitle ?? "" }
        case .yearOldest, .yearNewest:
            return decadeSections(for: filteredAlbums)
        case .dateAddedNewest, .dateAddedOldest:
            return addedYearSections(for: filteredAlbums)
        default:
            return alphabetSections(for: filteredAlbums) { $0.titleSort ?? $0.title }
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
                Menu {
                    Button {
                        sortOrder = sortOrder == .titleAscending ? .titleDescending : .titleAscending
                    } label: {
                        if isTitleSortActive {
                            Label("Title", systemImage: "checkmark")
                            Text(sortOrder == .titleDescending ? "Z to A" : "A to Z")
                        } else {
                            Text("Title")
                        }
                    }

                    Button {
                        sortOrder = sortOrder == .artistAscending ? .artistDescending : .artistAscending
                    } label: {
                        if isArtistSortActive {
                            Label("Artist", systemImage: "checkmark")
                            Text(sortOrder == .artistDescending ? "Z to A" : "A to Z")
                        } else {
                            Text("Artist")
                        }
                    }

                    Button {
                        sortOrder = sortOrder == .yearOldest ? .yearNewest : .yearOldest
                    } label: {
                        if isYearSortActive {
                            Label("Year", systemImage: "checkmark")
                            Text(sortOrder == .yearNewest ? "Newest First" : "Oldest First")
                        } else {
                            Text("Year")
                        }
                    }

                    Button {
                        sortOrder = sortOrder == .dateAddedNewest ? .dateAddedOldest : .dateAddedNewest
                    } label: {
                        if isDateAddedSortActive {
                            Label("Date Added", systemImage: "checkmark")
                            Text(sortOrder == .dateAddedOldest ? "Oldest First" : "Newest First")
                        } else {
                            Text("Date Added")
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .tint(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(selection: $viewMode) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(AlbumViewMode.grid)
                        Label("List", systemImage: "list.bullet").tag(AlbumViewMode.list)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: viewMode == .grid ? "square.grid.2x2" : "list.bullet")
                }
                .tint(.primary)
            }
        }
        .task(id: network.isConnected) {
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(albumSections, id: \.title) { section in
                            Text(section.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
                                .padding(.top, 16)
                                .padding(.bottom, 6)

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
                            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
                            .padding(.bottom, 12)
                        }
                    }
                }
                .tint(.secondary)
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
                        .sectionIndexLabel(section.title)
                    }
                }
                .listStyle(.plain)
                .listSectionIndexVisibility(isYearSortActive || isDateAddedSortActive ? .hidden : .automatic)
                .tint(.secondary)
            }
        }
    }

    private var isTitleSortActive: Bool {
        sortOrder == .titleAscending || sortOrder == .titleDescending
    }

    private var isArtistSortActive: Bool {
        sortOrder == .artistAscending || sortOrder == .artistDescending
    }

    private var isYearSortActive: Bool {
        sortOrder == .yearOldest || sortOrder == .yearNewest
    }

    private var isDateAddedSortActive: Bool {
        sortOrder == .dateAddedNewest || sortOrder == .dateAddedOldest
    }

    private var artworkPrefetchKey: String {
        "\(viewMode.rawValue)|\(filteredAlbums.count)|\(searchText)|\(sortOrder.rawValue)"
    }

    private func loadAlbums() async {
        if network.isConnected {
            await loadAlbumsOnline()
        } else {
            loadAlbumsOffline()
        }
    }

    private func loadAlbumsOffline() {
        var seen = Set<String>()
        var result: [PlexMetadata] = []
        for record in downloadManager.downloadedTracksSorted {
            let key = record.albumRatingKey ?? record.albumName
            guard seen.insert(key).inserted else { continue }
            result.append(PlexMetadata(
                ratingKey: record.albumRatingKey ?? "offline:\(record.albumName)",
                title: record.albumName,
                type: "album",
                parentTitle: record.artistName,
                thumb: record.thumbPath
            ))
        }
        result.sort { ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedAscending }
        withAnimation(.easeIn(duration: 0.25)) {
            albums = result
            isLoading = false
        }
    }

    private func loadAlbumsOnline() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }

        // Pre-populate from memory cache synchronously (no actor hop needed).
        // Eliminates the spinner flash when the memory cache is warm.
        let cacheKey = CacheKey.albums(serverId: server.machineIdentifier, sectionId: sectionId)
        if let cached = LibraryCache.shared.memoryCached([PlexMetadata].self, forKey: cacheKey), !cached.isEmpty {
            albums = cached
            isLoading = false
        }

        do {
            let result = try await client.cachedAlbums(server: server, sectionId: sectionId)
            withAnimation(.easeIn(duration: 0.25)) {
                albums = result
                isLoading = false
            }
        } catch {
#if DEBUG
            print("[AllAlbumsView] Failed to load albums: \(error)")
#endif
            isLoading = false
        }
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
        var sectionItems: [String: [PlexMetadata]] = [:]
        var sectionOrder: [String] = []
        for item in items {
            let title = alphabetSectionTitle(for: sortKey(item))
            if sectionItems[title] == nil { sectionOrder.append(title) }
            sectionItems[title, default: []].append(item)
        }
        return sectionOrder.map { ($0, sectionItems[$0]!) }
    }

    private func releaseYearInt(for album: PlexMetadata) -> Int {
        if let dateStr = album.originallyAvailableAt, dateStr.count >= 4, let y = Int(dateStr.prefix(4)) {
            return y
        }
        return album.year ?? 0
    }

    private func addedYearSections(for items: [PlexMetadata]) -> [(title: String, items: [PlexMetadata])] {
        var sectionItems: [String: [PlexMetadata]] = [:]
        var sectionOrder: [String] = []
        for item in items {
            let title: String
            if let ts = item.addedAt {
                let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(ts)))
                title = String(year)
            } else {
                title = "#"
            }
            if sectionItems[title] == nil { sectionOrder.append(title) }
            sectionItems[title, default: []].append(item)
        }
        return sectionOrder.map { ($0, sectionItems[$0]!) }
    }

    private func decadeSections(for items: [PlexMetadata]) -> [(title: String, items: [PlexMetadata])] {
        var sectionItems: [String: [PlexMetadata]] = [:]
        var sectionOrder: [String] = []
        for item in items {
            let year = releaseYearInt(for: item)
            let title = year > 0 ? "\((year / 10) * 10)s" : "#"
            if sectionItems[title] == nil { sectionOrder.append(title) }
            sectionItems[title, default: []].append(item)
        }
        return sectionOrder.map { ($0, sectionItems[$0]!) }
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

private enum AlbumSortOrder: String {
    case titleAscending
    case titleDescending
    case artistAscending
    case artistDescending
    case yearOldest
    case yearNewest
    case dateAddedNewest
    case dateAddedOldest
}

#if DEBUG
#Preview {
    NavigationStack {
        AllAlbumsView(previewAlbums: DevelopmentMockData.allAlbums)
    }
    .environment(AudioPlayerService())
}
#endif
