import SwiftUI

struct ArtistDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player
    @Environment(NetworkStatus.self) private var network
    @Environment(DownloadManager.self) private var downloadManager

    let artist: PlexMetadata
    @State private var viewModel: ArtistDetailViewModel
    @State private var selectedAlbum: PlexMetadata?
    @State private var selectedAppearsOnAlbum: PlexMetadata?
    @State private var selectedSimilarArtist: PlexMetadata?
    @State private var showsAllSimilarArtists = false
    @State private var showsAllTracks = false
    @State private var showsAllConcerts = false
    @State private var selectedConcert: ConcertEvent?
    @State private var heroIsHidden = false
    /// Set once the backdrop color lookup has finished, found or not, so the loading
    /// spinner never outlives a failed or offline fetch.
    @State private var backdropLookupFinished = false
    @State private var showsBioSheet = false
    @State private var showsChangePhotoSheet = false
    @State private var viewWidth: CGFloat = 393
    @State private var viewHeight: CGFloat = 852
    /// Vertical scroll position: 0 at rest, positive scrolled down, negative on overscroll.
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    /// Page backdrop, derived from the artist photo through the Apple Music
    /// tint algorithm with the artist-page lightness cap.
    private var backdropColor: Color {
        cachedBackdropColor ?? Color(.systemBackground)
    }

    private var cachedBackdropColor: Color? {
        let colors = ArtworkColorCache.shared
        // Keep the color of the photo we navigated in with while a refreshed thumb resolves,
        // so the page doesn't flash to the system background.
        return colors.color(for: displayArtist.thumb, colorScheme: colorScheme, style: .artist)
            ?? colors.color(for: artist.thumb, colorScheme: colorScheme, style: .artist)
    }

    /// True only while the backdrop color still has to be computed from the photo.
    /// Artists with a saved color skip this and open instantly.
    private var isAwaitingBackdrop: Bool {
        previewData == nil && displayArtist.thumb != nil && cachedBackdropColor == nil && !backdropLookupFinished
    }

    // Read-only views of the view model's state, so the body reads as before.
    private var displayArtist: PlexMetadata { viewModel.displayArtist }
    private var allTracks: [PlexMetadata] { viewModel.allTracks }
    private var topTracks: [PlexMetadata] { viewModel.topTracks }
    private var artistAlbums: [PlexMetadata] { viewModel.artistAlbums }
    private var appearsOnAlbums: [PlexMetadata] { viewModel.appearsOnAlbums }
    private var similarArtists: [PlexMetadata] { viewModel.similarArtists }
    private var contentReady: Bool { viewModel.contentReady }

    private var loadContext: ArtistDetailViewModel.Context {
        ArtistDetailViewModel.Context(
            server: serverConnection.currentServer,
            sectionId: serverConnection.currentLibrarySectionId,
            client: client,
            isConnected: network.isConnected,
            downloadManager: downloadManager
        )
    }

    /// Plex artist photos are almost always square, so the hero is a full-width square; the title and
    /// controls sit over the fade at its bottom edge.
    private var heroHeight: CGFloat { viewWidth }
    private let previewData: PreviewData?

    struct PreviewData {
        let resolvedArtist: PlexMetadata?
        let artistTracks: [PlexMetadata]
        let topTracks: [PlexMetadata]
        let artistAlbums: [PlexMetadata]
        var allTracks: [PlexMetadata] = []
        var appearsOnAlbums: [PlexMetadata] = []
        var similarArtists: [PlexMetadata] = []
    }

    init(artist: PlexMetadata, previewData: PreviewData? = nil) {
        self.artist = artist
        self.previewData = previewData
        _viewModel = State(initialValue: ArtistDetailViewModel(artist: artist, previewData: previewData))
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// iPad landscape (and an open iPhone Duo): photo, name and controls pinned on the left, content scrolling on the right.
    private var isWideLayout: Bool {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        if isPhone { return horizontalSizeClass == .regular || min(viewWidth, viewHeight) >= 500 }
        return horizontalSizeClass == .regular && viewWidth > viewHeight
    }

    private var sidePanelWidth: CGFloat {
        min(viewWidth * 0.38, 460)
    }

    private var albumGridColumns: [GridItem] {
        let count = isWideLayout ? 3 : (horizontalSizeClass == .regular ? 4 : 2)
        return Array(repeating: GridItem(.flexible(), spacing: AppStyle.ArtistDetailAlbumGrid.itemSpacing), count: count)
    }

    private var albums: [PlexMetadata] {
        artistAlbums.filter { !$0.isSingleOrEP }
    }

    private var singlesAndEPs: [PlexMetadata] {
        artistAlbums.filter { $0.isSingleOrEP }
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Full release date ("Jul 31, 2026"), falling back to the year.
    private static func releaseDateText(for album: PlexMetadata) -> String {
        if let raw = album.originallyAvailableAt, let date = isoDateFormatter.date(from: String(raw.prefix(10))) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return album.releaseYear
    }

    /// Falls back to counting loaded tracks when the album has no `leafCount`.
    private func songCount(in album: PlexMetadata) -> Int? {
        let count = allTracks.filter { $0.parentRatingKey == album.ratingKey }.count
        return count > 0 ? count : nil
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
                            .artworkBorder(cornerRadius: AppStyle.ArtistDetailAlbumGrid.artworkCornerRadius)
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
                .listRowBackground(backdropColor)
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
                            .artworkBorder(cornerRadius: AppStyle.ArtistDetailAlbumGrid.artworkCornerRadius)
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
                .listRowBackground(backdropColor)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, disclosureAction: (() -> Void)? = nil) -> some View {
        Group {
            if let disclosureAction {
                Button(action: disclosureAction) {
                    sectionHeaderRow(title, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all \(title)")
            } else {
                sectionHeaderRow(title, showsChevron: false)
            }
        }
        .listRowInsets(EdgeInsets(top: 16, leading: AppStyle.Spacing.pageHorizontal, bottom: 4, trailing: AppStyle.Spacing.pageHorizontal))
        .listRowSeparator(.hidden)
                .listRowBackground(backdropColor)
    }

    private func sectionHeaderRow(_ title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.primary)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .listRowBackground(backdropColor)
    }

    @ViewBuilder
    private func contentList(showsHero: Bool) -> some View {
        List {
            if showsHero {
                ArtistHeroHeaderView(
                    artist: displayArtist,
                    heroHeight: heroHeight,
                    backdropColor: backdropColor,
                    isHidden: heroIsHidden,
                    hasBio: !(displayArtist.summary ?? "").isEmpty,
                    onInfo: { showsBioSheet = true },
                    onChangePhoto: previewData == nil ? { showsChangePhotoSheet = true } : nil,
                    onPlay: playAll,
                    onShuffle: shuffleAll
                )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    // Clear so the photo drawn behind the list shows through.
                    .listRowBackground(Color.clear)
            }

            if artistAlbums.count > 1, let latestAlbum = artistAlbums.first {
                Button {
                    selectedAlbum = latestAlbum
                } label: {
                    HStack(spacing: 16) {
                        ArtworkView(
                            thumbPath: latestAlbum.thumb,
                            size: 100,
                            cornerRadius: 10
                        )
                        .artworkBorder(cornerRadius: 10)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.releaseDateText(for: latestAlbum))
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Text(latestAlbum.title)
                                .font(.headline)
                                .lineLimit(2)

                            if let count = latestAlbum.leafCount ?? songCount(in: latestAlbum) {
                                Text("\(count) \(count == 1 ? "Song" : "Songs")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 16, leading: AppStyle.Spacing.pageHorizontal, bottom: 8, trailing: AppStyle.Spacing.pageHorizontal))
                .listRowSeparator(.hidden)
                .listRowBackground(backdropColor)
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
                .listRowBackground(backdropColor)
            }

            if !artistAlbums.isEmpty {
                sectionHeader("Discography", disclosureAction: allTracks.isEmpty ? nil : { showsAllTracks = true })
                releaseGrid(artistAlbums)
            }

            if !appearsOnAlbums.isEmpty {
                sectionHeader("Appears On")
                appearsOnGrid(appearsOnAlbums)
            }

            if !viewModel.concerts.isEmpty {
                sectionHeader("All Upcoming Concerts", disclosureAction: { showsAllConcerts = true })

                ForEach(viewModel.concerts.prefix(3)) { concert in
                    ArtistConcertRowView(
                        concert: concert,
                        showsDivider: concert.id != viewModel.concerts.prefix(3).last?.id,
                        dividerColor: .white.opacity(0.25)
                    ) { selectedConcert = concert }
                        .listRowInsets(EdgeInsets(top: 0, leading: AppStyle.Spacing.pageHorizontal, bottom: 0, trailing: AppStyle.Spacing.pageHorizontal))
                        .listRowBackground(backdropColor)
                }
            }

            if contentReady && !similarArtists.isEmpty {
                if !similarArtists.isEmpty {
                    sectionHeader(
                        "Similar Artists",
                        disclosureAction: similarArtists.count > 8 ? { showsAllSimilarArtists = true } : nil
                    )

                    similarArtistsRail(Array(similarArtists.prefix(8)))
                }
            }

        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background {
            ZStack(alignment: .top) {
                backdropColor
                if showsHero {
                    // The photo lives behind the list instead of inside a row, so it is driven
                    // by the scroll view's own offset and never lags or gets recycled with a cell.
                    ArtistHeroPhotoView(
                        artist: displayArtist,
                        heroHeight: heroHeight,
                        backdropColor: backdropColor,
                        scrollOffset: scrollOffset,
                        isHidden: $heroIsHidden
                    )
                }
            }
            .ignoresSafeArea()
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, newValue in
            scrollOffset = newValue
        }
        .scrollEdgeEffectHidden(showsHero, for: .top)
        .ignoresSafeArea(edges: showsHero ? .top : [])
    }

    private func playAll() {
        guard !allTracks.isEmpty else { return }
        player.play(tracks: allTracks)
    }

    private func shuffleAll() {
        guard !allTracks.isEmpty else { return }
        player.play(tracks: allTracks)
        if !player.isShuffled {
            player.toggleShuffle()
        }
    }

    var body: some View {
        Group {
            if isWideLayout {
                HStack(spacing: 0) {
                    ArtistSidePanelView(
                        artist: displayArtist,
                        width: sidePanelWidth,
                        backdropColor: backdropColor,
                        hasBio: !(displayArtist.summary ?? "").isEmpty,
                        onInfo: { showsBioSheet = true },
                        onChangePhoto: previewData == nil ? { showsChangePhotoSheet = true } : nil,
                        onPlay: playAll,
                        onShuffle: shuffleAll
                    )
                    .frame(width: sidePanelWidth + AppStyle.Spacing.pageHorizontal * 2)
                    .background(backdropColor.ignoresSafeArea())

                    contentList(showsHero: false)
                }
            } else {
                contentList(showsHero: true)
            }
        }
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
        .navigationDestination(isPresented: $showsAllConcerts) {
            ArtistConcertsListView(
                artist: displayArtist,
                concerts: viewModel.concerts,
                backdropColor: backdropColor,
                onShuffle: shuffleAll
            )
        }
        .navigationDestination(item: $selectedConcert) { concert in
            ArtistConcertDetailView(
                concert: concert,
                artist: displayArtist,
                backdropColor: backdropColor,
                onShuffle: shuffleAll
            )
        }
        .navigationDestination(isPresented: $showsAllTracks) {
            ArtistAllTracksListView(tracks: allTracks, albums: artistAlbums + appearsOnAlbums)
        }
        // Artist pages always use white text; the backdrop is kept dark enough for it.
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // Measure the full container width including safe areas, so the square hero spans the screen.
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(
                width: (proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing).rounded(),
                height: proxy.size.height.rounded()
            )
        } action: { newSize in
            if abs(newSize.width - viewWidth) > 1 { viewWidth = newSize.width }
            if abs(newSize.height - viewHeight) > 1 { viewHeight = newSize.height }
        }
        .overlay {
            if isAwaitingBackdrop {
                ZStack {
                    Color(.systemBackground)
                    ProgressView()
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isAwaitingBackdrop)
        .task(id: displayArtist.thumb) {
            if let server = serverConnection.currentServer, previewData == nil {
                await ArtworkColorCache.shared.resolveColor(for: displayArtist.thumb, using: client, server: server, style: .artist)
            }
            // A newer thumb's lookup has taken over; let it decide when loading ends.
            if !Task.isCancelled { backdropLookupFinished = true }
        }
        .task(id: artist.ratingKey) {
            // Never hold the page behind the spinner on a slow network.
            try? await Task.sleep(for: .seconds(3))
            backdropLookupFinished = true
        }
        .task(id: artist.ratingKey) {
            await viewModel.load(loadContext)
        }
        .task(id: artist.ratingKey) {
            await viewModel.loadConcerts(isConnected: network.isConnected)
        }
        .sheet(isPresented: $showsChangePhotoSheet) {
            ChangeArtworkSheet(ratingKey: artist.ratingKey, subject: "artist") {
                // The new photo has a new thumb path, so the hero reloads it and the
                // backdrop color is picked again from it (see the thumb-keyed tasks above).
                await viewModel.reloadArtist(loadContext)
            }
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

#if DEBUG
#Preview {
    NavigationStack {
        ArtistDetailView(
            artist: DevelopmentMockData.previewArtist,
            previewData: .init(
                resolvedArtist: DevelopmentMockData.previewArtist,
                artistTracks: DevelopmentMockData.artistAllTracks,
                topTracks: DevelopmentMockData.artistTopTracks,
                artistAlbums: DevelopmentMockData.artistAlbums,
                allTracks: DevelopmentMockData.artistAllTracks
            )
        )
    }
    .environment(AudioPlayerService())
}
#endif
