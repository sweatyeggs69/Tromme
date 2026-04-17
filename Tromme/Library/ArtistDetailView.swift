import SwiftUI

struct ArtistDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    let artist: PlexMetadata
    @State private var resolvedArtist: PlexMetadata?
    @State private var artistTracks: [PlexMetadata] = []
    @State private var topTracks: [PlexMetadata] = []
    @State private var artistAlbums: [PlexMetadata] = []
    @State private var selectedAlbum: PlexMetadata?
    @State private var heroMinY: CGFloat = 0
    @State private var showsBioSheet = false

    private var displayArtist: PlexMetadata {
        resolvedArtist ?? artist
    }

    private var showsCollapsedTitle: Bool {
        heroMinY < -80
    }

    private let heroHeight: CGFloat = 400
    private let previewData: PreviewData?

    struct PreviewData {
        let resolvedArtist: PlexMetadata?
        let artistTracks: [PlexMetadata]
        let topTracks: [PlexMetadata]
        let artistAlbums: [PlexMetadata]
    }

    init(artist: PlexMetadata, previewData: PreviewData? = nil) {
        self.artist = artist
        self.previewData = previewData
        _resolvedArtist = State(initialValue: previewData?.resolvedArtist)
        _artistTracks = State(initialValue: previewData?.artistTracks ?? [])
        _topTracks = State(initialValue: previewData?.topTracks ?? [])
        _artistAlbums = State(initialValue: previewData?.artistAlbums ?? [])
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var albumGridColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: AppStyle.ArtistDetailAlbumGrid.itemSpacing), count: count)
    }

    private var albums: [PlexMetadata] {
        artistAlbums.filter { !$0.isSingleOrEP }
    }

    private var singlesAndEPs: [PlexMetadata] {
        artistAlbums.filter { $0.isSingleOrEP }
    }

    private func releaseGrid(_ releases: [PlexMetadata]) -> some View {
        LazyVGrid(columns: albumGridColumns, spacing: AppStyle.ArtistDetailAlbumGrid.rowSpacing) {
            ForEach(releases) { album in
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

                        Text(album.releaseYear)
                            .appItemSubtitleStyle()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: AppStyle.Spacing.pageHorizontal, bottom: 0, trailing: AppStyle.Spacing.pageHorizontal))
        .listRowSeparator(.hidden)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 16, leading: AppStyle.Spacing.pageHorizontal, bottom: 4, trailing: AppStyle.Spacing.pageHorizontal))
            .listRowSeparator(.hidden)
    }

    var body: some View {
        List {
            ArtistHeroHeaderView(artist: displayArtist, heroHeight: heroHeight) {
                    guard !artistTracks.isEmpty else { return }
                    player.play(tracks: artistTracks)
                    if !player.isShuffled {
                        player.toggleShuffle()
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: ArtistHeroMinYPreferenceKey.self,
                                value: proxy.frame(in: .named("artistDetailScroll")).minY
                            )
                    }
                )

            if artistAlbums.count > 1, let latestAlbum = artistAlbums.first {
                sectionHeader("Latest")

                Button {
                    selectedAlbum = latestAlbum
                } label: {
                    HStack(spacing: 14) {
                        ArtworkView(
                            thumbPath: latestAlbum.thumb,
                            size: 120,
                            cornerRadius: AppStyle.Radius.card
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text(latestAlbum.releaseYear)
                                if let format = latestAlbum.formatLabel {
                                    Text("·")
                                    Text(format)
                                }
                            }
                            .appItemSubtitleStyle()

                            Text(latestAlbum.title)
                                .appItemTitleStyle()
                                .lineLimit(2)

                            if let count = latestAlbum.leafCount {
                                Text("\(count) \(count == 1 ? "song" : "songs")")
                                    .appItemSubtitleStyle()
                            }
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: AppStyle.Spacing.pageHorizontal, bottom: 0, trailing: AppStyle.Spacing.pageHorizontal))
                .listRowSeparator(.hidden)
            }

            if !topTracks.isEmpty {
                sectionHeader("Top Songs")

                HorizontalTrackGrid(
                    tracks: Array(topTracks.prefix(10)),
                    rowCount: min(5, topTracks.count),
                    showArtist: false,
                    subtitleProvider: { track in
                        let albumYear = artistAlbums.first(where: { $0.ratingKey == track.parentRatingKey })?.year
                        return [track.parentTitle, albumYear.map(String.init)]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }

            if !artistAlbums.isEmpty {
                sectionHeader("Discography")
                releaseGrid(artistAlbums)
            }

        }
        .coordinateSpace(name: "artistDetailScroll")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album, sourceArtistRatingKey: artist.ratingKey)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(displayArtist.title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(showsCollapsedTitle ? 1 : 0)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if displayArtist.summary != nil {
                    Menu {
                        Button {
                            showsBioSheet = true
                        } label: {
                            Label("Artist Info", systemImage: "info.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .tint(.primary)
                }
            }
        }
        .listStyle(.plain)
        .ignoresSafeArea(edges: .top)
        .onPreferenceChange(ArtistHeroMinYPreferenceKey.self) { value in
            heroMinY = value
        }
        .animation(.easeInOut(duration: 0.2), value: showsCollapsedTitle)
        .task {
            guard previewData == nil else { return }
            guard let server = serverConnection.currentServer,
                  let sectionId = serverConnection.currentLibrarySectionId else { return }

            // Load all data in parallel instead of sequentially
            async let metadataReq = client.cachedMetadata(server: server, ratingKey: artist.ratingKey)
            async let topTracksReq = client.cachedTopTracks(server: server, sectionId: sectionId, artistRatingKey: artist.ratingKey)
            async let childrenReq = client.cachedChildren(server: server, ratingKey: artist.ratingKey)
            async let allTracksReq = client.cachedTracks(server: server, sectionId: sectionId)

            resolvedArtist = try? await metadataReq

            let fetchedTopTracks = (try? await topTracksReq) ?? []

            var children = (try? await childrenReq) ?? []

            let allTracks = (try? await allTracksReq) ?? []
            artistTracks = allTracks.filter {
                $0.grandparentRatingKey == artist.ratingKey
                || $0.grandparentTitle?.localizedCaseInsensitiveCompare(artist.title) == .orderedSame
            }

            // Find releases referenced by tracks but missing from children
            let childrenKeys = Set(children.map(\.ratingKey))
            let missingKeys = Set(artistTracks.compactMap(\.parentRatingKey))
                .subtracting(childrenKeys)

            if !missingKeys.isEmpty {
                let missing = await withTaskGroup(of: PlexMetadata?.self) { group in
                    for key in missingKeys {
                        group.addTask { try? await client.cachedMetadata(server: server, ratingKey: key) }
                    }
                    var results: [PlexMetadata] = []
                    for await item in group {
                        if let item { results.append(item) }
                    }
                    return results
                }
                children.append(contentsOf: missing)
            }

            artistAlbums = children.sorted {
                let date0 = $0.originallyAvailableAt ?? ""
                let date1 = $1.originallyAvailableAt ?? ""
                if date0 != date1 { return date0 > date1 }
                if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) > ($1.year ?? 0) }
                return ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title)
            }

            // Fallback: if Plex returned no top tracks, use local sort by viewCount
            topTracks = fetchedTopTracks.isEmpty
                ? artistTracks.sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
                : fetchedTopTracks
        }
        .sheet(isPresented: $showsBioSheet) {
            if let summary = displayArtist.summary, !summary.isEmpty {
                NavigationStack {
                    ScrollView {
                        Text(summary)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .navigationTitle("Biography")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}

private struct ArtistHeroHeaderView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    let artist: PlexMetadata
    let heroHeight: CGFloat
    var onShuffle: (() -> Void)?

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .global).minY
            let isOverscrolling = minY > 0
            let stretchHeight = isOverscrolling ? heroHeight + minY : heroHeight
            let stretchOffset = isOverscrolling ? -minY : 0

            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                    }
                }
                .frame(width: geo.size.width, height: stretchHeight, alignment: .top)
                .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                HStack(alignment: .bottom) {
                    Text(artist.title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Spacer()

                    if let onShuffle {
                        Button {
                            onShuffle()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.black)
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.85), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .offset(y: stretchOffset)
        }
        .frame(height: heroHeight)
        .task(id: artist.thumb) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let server = serverConnection.currentServer else {
            image = nil
            return
        }
        let artworkPath = artist.thumb
        guard let url = client.artworkURL(server: server, path: artworkPath, width: 1000, height: 1000) else {
            image = nil
            return
        }
        let resolvedImage = await ImageCache.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = resolvedImage?.squareCropped()
    }
}

private extension UIImage {
    func squareCropped() -> UIImage {
        let side = min(size.width, size.height)
        guard side < max(size.width, size.height) else { return self }
        let origin = CGPoint(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage, let cropped = cgImage.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}

private struct ArtistHeroMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ArtistDetailView(
            artist: DevelopmentMockData.previewArtist,
            previewData: .init(
                resolvedArtist: DevelopmentMockData.previewArtist,
                artistTracks: DevelopmentMockData.artistAllTracks,
                topTracks: DevelopmentMockData.artistTopTracks,
                artistAlbums: DevelopmentMockData.artistAlbums
            )
        )
    }
    .environment(AudioPlayerService())
}
#endif
