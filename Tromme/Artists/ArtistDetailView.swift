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
    @State private var heroIsHidden = false
    @State private var showsBioSheet = false
    @State private var viewHeight: CGFloat = 800
    /// Vertical scroll position: 0 at rest, positive scrolled down, negative on overscroll.
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    /// Page backdrop, derived from the artist photo through the Apple Music
    /// tint algorithm with the artist-page lightness cap.
    private var backdropColor: Color {
        ArtworkColorCache.shared.color(for: displayArtist.thumb, colorScheme: colorScheme, style: .artist) ?? Color(.systemBackground)
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

    /// The photo area takes about 46% of the screen height; the extra room holds the title and controls over the fade.
    private var photoHeight: CGFloat { viewHeight * 0.46 }
    private var heroHeight: CGFloat { photoHeight + 110 }
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

    var body: some View {
        List {
            ArtistHeroHeaderView(
                artist: displayArtist,
                heroHeight: heroHeight,
                backdropColor: backdropColor,
                isHidden: heroIsHidden,
                hasBio: !(displayArtist.summary ?? "").isEmpty,
                onInfo: { showsBioSheet = true },
                onPlay: {
                    guard !allTracks.isEmpty else { return }
                    player.play(tracks: allTracks)
                },
                onShuffle: {
                    guard !allTracks.isEmpty else { return }
                    player.play(tracks: allTracks)
                    if !player.isShuffled {
                        player.toggleShuffle()
                    }
                }
            )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                // Clear so the photo drawn behind the list shows through.
                .listRowBackground(Color.clear)

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
                            .fill(backdropColor.contrastForeground.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(backdropColor.contrastForeground.opacity(0.12), lineWidth: 0.5)
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
        .navigationDestination(isPresented: $showsAllTracks) {
            ArtistAllTracksListView(tracks: allTracks, albums: artistAlbums + appearsOnAlbums)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background {
            ZStack(alignment: .top) {
                backdropColor
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
            .ignoresSafeArea()
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, newValue in
            scrollOffset = newValue
        }
        .foregroundStyle(backdropColor.contrastForeground)
        .environment(\.colorScheme, backdropColor.isLightColor() ? .light : .dark)
        .scrollEdgeEffectHidden(true, for: .top)
        .ignoresSafeArea(edges: .top)
        // Measure the full container height including safe areas, so the hero doesn't resize
        // (and re-crop the photo) when the tab bar minimizes or the bottom inset changes on scroll.
        .onGeometryChange(for: CGFloat.self) { proxy in
            (proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom).rounded()
        } action: { newHeight in
            if abs(newHeight - viewHeight) > 1 { viewHeight = newHeight }
        }
        .task(id: displayArtist.thumb) {
            guard previewData == nil, let server = serverConnection.currentServer else { return }
            await ArtworkColorCache.shared.resolveColor(for: displayArtist.thumb, using: client, server: server, style: .artist)
        }
        .task(id: artist.ratingKey) {
            await viewModel.load(loadContext)
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
