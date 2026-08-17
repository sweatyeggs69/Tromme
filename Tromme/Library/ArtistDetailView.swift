import SwiftUI

struct ArtistDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player
    @Environment(NetworkStatus.self) private var network
    @Environment(DownloadManager.self) private var downloadManager

    let artist: PlexMetadata
    @State private var resolvedArtist: PlexMetadata?
    @State private var artistTracks: [PlexMetadata] = []
    @State private var topTracks: [PlexMetadata] = []
    @State private var artistAlbums: [PlexMetadata] = []
    @State private var selectedAlbum: PlexMetadata?
    @State private var appearsOnAlbums: [PlexMetadata] = []
    @State private var selectedAppearsOnAlbum: PlexMetadata?
    @State private var similarArtists: [PlexMetadata] = []
    @State private var selectedSimilarArtist: PlexMetadata?
    @State private var showsAllSimilarArtists = false
    @State private var heroMinY: CGFloat = 0
    @State private var heroIsHidden = false
    @State private var showsBioSheet = false

    private var displayArtist: PlexMetadata {
        resolvedArtist ?? artist
    }

    private var showsCollapsedTitle: Bool {
        heroMinY < -80 || heroIsHidden
    }

    private let heroHeight: CGFloat = 400
    private let previewData: PreviewData?

    struct PreviewData {
        let resolvedArtist: PlexMetadata?
        let artistTracks: [PlexMetadata]
        let topTracks: [PlexMetadata]
        let artistAlbums: [PlexMetadata]
        var appearsOnAlbums: [PlexMetadata] = []
        var similarArtists: [PlexMetadata] = []
    }

    init(artist: PlexMetadata, previewData: PreviewData? = nil) {
        self.artist = artist
        self.previewData = previewData
        _resolvedArtist = State(initialValue: previewData?.resolvedArtist)
        _artistTracks = State(initialValue: previewData?.artistTracks ?? [])
        _topTracks = State(initialValue: previewData?.topTracks ?? [])
        _artistAlbums = State(initialValue: previewData?.artistAlbums ?? [])
        _appearsOnAlbums = State(initialValue: previewData?.appearsOnAlbums ?? [])
        _similarArtists = State(initialValue: previewData?.similarArtists ?? [])
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let similarSectionBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.15)
            : UIColor(white: 0.0, alpha: 0.05)
    })

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

    private func appearsOnGrid(_ albums: [PlexMetadata]) -> some View {
        LazyVGrid(columns: albumGridColumns, spacing: AppStyle.ArtistDetailAlbumGrid.rowSpacing) {
            ForEach(albums) { album in
                Button {
                    selectedAppearsOnAlbum = album
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

                        Text([album.releaseYear, album.parentTitle]
                            .compactMap { s in (s?.isEmpty == false) ? s : nil }
                            .joined(separator: " · "))
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

    @ViewBuilder
    private func sectionHeader(_ title: String, disclosureAction: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title3.bold())

            if let disclosureAction {
                Button(action: disclosureAction) {
                    Image(systemName: "chevron.right")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all \(title)")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets(top: 16, leading: AppStyle.Spacing.pageHorizontal, bottom: 4, trailing: AppStyle.Spacing.pageHorizontal))
        .listRowSeparator(.hidden)
    }

    private func similarArtistsRail(_ artists: [PlexMetadata]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(artists) { artist in
                    Button {
                        selectedSimilarArtist = artist
                    } label: {
                        VStack(alignment: .center, spacing: 6) {
                            ArtworkView(
                                thumbPath: artist.thumb,
                                size: 120,
                                cornerRadius: 60
                            )

                            Text(artist.title)
                                .font(AppStyle.Typography.itemTitle)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 120)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
        }
        .scrollTargetBehavior(.viewAligned)
        .padding(.bottom, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
    }

    var body: some View {
        List {
            ArtistHeroHeaderView(artist: displayArtist, heroHeight: heroHeight, isHidden: $heroIsHidden) {
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

            if !appearsOnAlbums.isEmpty {
                sectionHeader("Appears On")
                appearsOnGrid(appearsOnAlbums)
            }

            let hasBio = !(displayArtist.summary ?? "").isEmpty
            if hasBio || !similarArtists.isEmpty {
                if let summary = displayArtist.summary, !summary.isEmpty {
                    sectionHeader("About \(displayArtist.title)")
                        .listRowBackground(similarSectionBackground)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Read More") {
                            showsBioSheet = true
                        }
                        .font(.subheadline.bold())
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: AppStyle.Spacing.pageHorizontal, bottom: 16, trailing: AppStyle.Spacing.pageHorizontal))
                    .listRowSeparator(.hidden)
                    .listRowBackground(similarSectionBackground)
                }

                if !similarArtists.isEmpty {
                    sectionHeader(
                        "Similar Artists",
                        disclosureAction: similarArtists.count > 8 ? { showsAllSimilarArtists = true } : nil
                    )
                    .listRowBackground(similarSectionBackground)

                    similarArtistsRail(Array(similarArtists.prefix(8)))
                        .listRowBackground(similarSectionBackground)
                }
            }

        }
        .coordinateSpace(name: "artistDetailScroll")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album, sourceArtistRatingKey: artist.ratingKey)
        }
        .navigationDestination(item: $selectedAppearsOnAlbum) { album in
            AlbumDetailView(album: album, sourceArtistRatingKey: album.parentRatingKey)
        }
        .navigationDestination(item: $selectedSimilarArtist) { artist in
            ArtistDetailView(artist: artist)
        }
        .navigationDestination(isPresented: $showsAllSimilarArtists) {
            SimilarArtistsGridView(artists: similarArtists)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(displayArtist.title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(showsCollapsedTitle ? 1 : 0)
            }
        }
        .listStyle(.plain)
        .ignoresSafeArea(edges: .top)
        .onPreferenceChange(ArtistHeroMinYPreferenceKey.self) { value in
            heroMinY = value
        }
        .animation(.easeInOut(duration: 0.2), value: showsCollapsedTitle)
        .task(id: network.isConnected) {
            guard previewData == nil else { return }

            if !network.isConnected {
                loadOfflineContent()
                return
            }

            guard let server = serverConnection.currentServer,
                  let sectionId = serverConnection.currentLibrarySectionId else { return }

            // Load all data in parallel instead of sequentially
            async let metadataReq = client.cachedMetadata(server: server, ratingKey: artist.ratingKey)
            async let topTracksReq = client.cachedTopTracks(server: server, sectionId: sectionId, artistRatingKey: artist.ratingKey)
            async let releasesReq = client.cachedArtistReleases(server: server, sectionId: sectionId, artist: artist)
            async let artistTracksReq = client.cachedArtistTracks(server: server, sectionId: sectionId, artist: artist)
            async let appearsOnReq = client.appearsOnAlbums(server: server, sectionId: sectionId, artistRatingKey: artist.ratingKey, artistTitle: artist.title)
            async let similarArtistsReq = client.similarArtists(server: server, sectionId: sectionId, seedArtistKey: artist.ratingKey)

            resolvedArtist = try? await metadataReq

            let fetchedTopTracks = (try? await topTracksReq) ?? []
            artistTracks = (try? await artistTracksReq) ?? []
            artistAlbums = (try? await releasesReq) ?? []
            appearsOnAlbums = (try? await appearsOnReq) ?? []
            similarArtists = (try? await similarArtistsReq) ?? []

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

    private func loadOfflineContent() {
        let artistKey = artist.ratingKey
        let artistTitle = artist.title
        let records = downloadManager.downloadedTracksSorted.filter { record in
            record.artistRatingKey == artistKey || record.artistName == artistTitle
        }
        var seenAlbums = Set<String>()
        artistAlbums = records.compactMap { record -> PlexMetadata? in
            let key = record.albumRatingKey ?? record.albumName
            guard seenAlbums.insert(key).inserted else { return nil }
            return PlexMetadata(
                ratingKey: record.albumRatingKey ?? "offline:\(record.albumName)",
                title: record.albumName,
                type: "album",
                parentTitle: record.artistName,
                thumb: record.thumbPath
            )
        }
        artistTracks = records.map { $0.asPlexMetadata() }
        topTracks = artistTracks
        appearsOnAlbums = []
    }
}

private struct SimilarArtistsGridView: View {
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

private struct ArtistHeroHeaderView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(NetworkStatus.self) private var network

    let artist: PlexMetadata
    let heroHeight: CGFloat
    @Binding var isHidden: Bool
    var onShuffle: (() -> Void)?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if isHidden {
                Color.clear
                    .frame(height: 0)
            } else {
                heroContent
            }
        }
        .task(id: artist.thumb) {
            await loadImage()
        }
    }

    private var heroContent: some View {
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
    }

    private func loadImage() async {
        guard let server = serverConnection.currentServer else {
            image = nil
            isHidden = true
            return
        }
        let artworkPath = artist.thumb
        guard let url = client.artworkURL(server: server, path: artworkPath, width: 1000, height: 1000) else {
            image = nil
            isHidden = !network.isConnected
            return
        }
        let resolvedImage = await ImageCache.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = resolvedImage?.squareCropped()
        isHidden = image == nil && !network.isConnected
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
