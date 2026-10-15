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
    @State private var allTracks: [PlexMetadata] = []
    @State private var topTracks: [PlexMetadata] = []
    @State private var artistAlbums: [PlexMetadata] = []
    @State private var selectedAlbum: PlexMetadata?
    @State private var appearsOnAlbums: [PlexMetadata] = []
    @State private var selectedAppearsOnAlbum: PlexMetadata?
    @State private var similarArtists: [PlexMetadata] = []
    @State private var selectedSimilarArtist: PlexMetadata?
    @State private var showsAllSimilarArtists = false
    @State private var showsAllTracks = false
    @State private var heroIsHidden = false
    @State private var showsBioSheet = false
    @State private var contentReady = false
    @State private var viewHeight: CGFloat = 800
    /// Vertical scroll position: 0 at rest, positive scrolled down, negative on overscroll.
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    /// Page backdrop, derived from the artist photo through the same
    /// Apple Music tint algorithm the album page uses.
    private var backdropColor: Color {
        ArtworkColorCache.shared.color(for: displayArtist.thumb) ?? Color(.systemBackground)
    }

    private var displayArtist: PlexMetadata {
        resolvedArtist ?? artist
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
        _resolvedArtist = State(initialValue: previewData?.resolvedArtist)
        _artistTracks = State(initialValue: previewData?.artistTracks ?? [])
        _allTracks = State(initialValue: previewData?.allTracks ?? previewData?.artistTracks ?? [])
        _topTracks = State(initialValue: previewData?.topTracks ?? [])
        _artistAlbums = State(initialValue: previewData?.artistAlbums ?? [])
        _appearsOnAlbums = State(initialValue: previewData?.appearsOnAlbums ?? [])
        _similarArtists = State(initialValue: previewData?.similarArtists ?? [])
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
            await ArtworkColorCache.shared.resolveColor(for: displayArtist.thumb, using: client, server: server)
        }
        .task(id: artist.ratingKey) {
            guard previewData == nil else { return }

            if !network.isConnected {
                // Prefer disk-cached data so non-downloaded albums and all tracks appear.
                let didLoadFromCache = await loadFromDiskCache(artist: artist)
                if !didLoadFromCache { loadOfflineContent() }
                return
            }

            guard let server = serverConnection.currentServer,
                  let sectionId = serverConnection.currentLibrarySectionId else { return }

            // Load all data in parallel instead of sequentially
            async let metadataReq = client.cachedMetadata(server: server, ratingKey: artist.ratingKey)
            async let releasesReq = client.cachedArtistReleases(server: server, sectionId: sectionId, artist: artist)
            async let artistTracksReq = client.cachedArtistTracks(server: server, sectionId: sectionId, artist: artist)
            async let allTracksReq = client.allArtistTracks(server: server, sectionId: sectionId, artist: artist)
            async let appearsOnReq = client.appearsOnAlbums(server: server, sectionId: sectionId, artistRatingKey: artist.ratingKey, artistTitle: artist.title)
            async let similarArtistsReq = client.similarArtists(server: server, sectionId: sectionId, seedArtistKey: artist.ratingKey)

            let fetchedMetadata = try? await metadataReq
            let fetchedArtistTracks = (try? await artistTracksReq) ?? []
            let fetchedAllTracks = (try? await allTracksReq) ?? fetchedArtistTracks
            let fetchedAlbums = (try? await releasesReq) ?? []
            let fetchedAppearsOn = (try? await appearsOnReq) ?? []
            let fetchedSimilar = (try? await similarArtistsReq) ?? []

            withAnimation(.easeIn(duration: 0.25)) {
                resolvedArtist = fetchedMetadata
                artistTracks = fetchedArtistTracks
                allTracks = fetchedAllTracks
                artistAlbums = fetchedAlbums
                appearsOnAlbums = fetchedAppearsOn
                similarArtists = fetchedSimilar
                topTracks = Array(
                    fetchedAllTracks
                        .sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
                        .prefix(10)
                )
                contentReady = true
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

    /// Reads artist data from disk cache without any network calls.
    /// Returns true if enough data was found to populate the view.
    private func loadFromDiskCache(artist: PlexMetadata) async -> Bool {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return false }
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)

        async let storedMetadata = LibraryStore.shared.anyMetadata(ratingKey: artist.ratingKey, serverId: server.machineIdentifier)
        async let storedAlbums = LibraryStore.shared.children(of: artist.ratingKey, scope: scope)
        async let storedTracks = LibraryStore.shared.tracks(byArtist: artist.ratingKey, scope: scope)

        let (metadata, albums, tracks) = await (storedMetadata, storedAlbums, storedTracks)

        guard !tracks.isEmpty else { return false }

        withAnimation(.easeIn(duration: 0.25)) {
            resolvedArtist = metadata
            artistTracks = tracks
            allTracks = tracks
            artistAlbums = albums
            topTracks = Array(tracks.sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }.prefix(10))
            appearsOnAlbums = []
            similarArtists = []
            contentReady = true
        }
        return true
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
        allTracks = artistTracks
        topTracks = artistTracks
        appearsOnAlbums = []
        contentReady = true
    }
}

private struct ArtistAllTracksListView: View {
    @Environment(AudioPlayerService.self) private var player

    let tracks: [PlexMetadata]
    /// Release date/year live on the album, not the track — Plex doesn't return
    /// `originallyAvailableAt`/`year` on track objects, so sorting off the track's own
    /// (always-empty) fields silently no-ops. Look them up from the artist's albums instead.
    let albums: [PlexMetadata]
    @State private var trackNavigationTarget: PlexMetadata?
    @AppStorage("artistAllTracksSortNewestFirst") private var sortNewestFirst = true

    private var albumReleaseInfo: [String: (date: String, year: Int)] {
        Dictionary(
            albums.map { ($0.ratingKey, (date: $0.originallyAvailableAt ?? "", year: $0.year ?? 0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Albums ordered by release date (direction set by `sortNewestFirst`); tracks within
    /// the same album always stay in album order (disc, then track number).
    private var sortedTracks: [PlexMetadata] {
        let releaseInfo = albumReleaseInfo
        return tracks.sorted { lhs, rhs in
            let leftInfo = lhs.parentRatingKey.flatMap { releaseInfo[$0] }
            let rightInfo = rhs.parentRatingKey.flatMap { releaseInfo[$0] }

            let leftDate = leftInfo?.date ?? lhs.originallyAvailableAt ?? ""
            let rightDate = rightInfo?.date ?? rhs.originallyAvailableAt ?? ""
            if leftDate != rightDate {
                return sortNewestFirst ? (leftDate > rightDate) : (leftDate < rightDate)
            }

            let leftYear = leftInfo?.year ?? lhs.year ?? 0
            let rightYear = rightInfo?.year ?? rhs.year ?? 0
            if leftYear != rightYear {
                return sortNewestFirst ? (leftYear > rightYear) : (leftYear < rightYear)
            }

            let leftAlbum = lhs.parentTitle ?? ""
            let rightAlbum = rhs.parentTitle ?? ""
            if leftAlbum != rightAlbum {
                return leftAlbum.localizedStandardCompare(rightAlbum) == .orderedAscending
            }

            let leftDisc = lhs.parentIndex ?? 0
            let rightDisc = rhs.parentIndex ?? 0
            if leftDisc != rightDisc { return leftDisc < rightDisc }

            return (lhs.index ?? 0) < (rhs.index ?? 0)
        }
    }

    var body: some View {
        List {
            ForEach(Array(sortedTracks.enumerated()), id: \.element.id) { index, track in
                TrackRowView(
                    track: track,
                    tracks: sortedTracks,
                    index: index,
                    showArtwork: true,
                    showArtist: true,
                    showTrackNumber: false,
                    artworkSize: AppStyle.TrackList.browseArtworkSize,
                    artworkCornerRadius: AppStyle.TrackList.artworkCornerRadius,
                    onNavigate: { trackNavigationTarget = $0 }
                )
                .listRowInsets(AppStyle.TrackList.rowInsets)
            }
        }
        .listStyle(.plain)
        .listRowSpacing(AppStyle.TrackList.rowSpacing)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $trackNavigationTarget) { target in
            if target.type == "artist" {
                ArtistDetailView(artist: target)
            } else {
                AlbumDetailView(album: target)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sortNewestFirst.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .symbolEffect(.bounce, value: sortNewestFirst)
                }
                .tint(.primary)
                .accessibilityLabel(sortNewestFirst ? "Newest First" : "Oldest First")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    player.play(tracks: sortedTracks, startingAt: 0)
                } label: {
                    Image(systemName: "play.fill")
                }
                .tint(.primary)
                .disabled(sortedTracks.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    var shuffled = sortedTracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled, startingAt: 0)
                } label: {
                    Image(systemName: "shuffle")
                }
                .tint(.primary)
                .disabled(sortedTracks.isEmpty)
            }
        }
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
    let artist: PlexMetadata
    let heroHeight: CGFloat
    let backdropColor: Color
    var isHidden: Bool
    var hasBio = false
    var onInfo: (() -> Void)?
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    var body: some View {
        if isHidden {
            VStack(spacing: 20) {
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(backdropColor.contrastForeground)
                    .multilineTextAlignment(.center)
                controls
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.bottom, 12)
        } else {
            // Title and controls sit on the bottom edge of the row and scroll with it; the
            // photo behind them is drawn by ArtistHeroPhotoView.
            VStack(spacing: 20) {
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(backdropColor.contrastForeground)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppStyle.Spacing.pageHorizontal)

                controls
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight, alignment: .bottom)
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button {
                onInfo?()
            } label: {
                Image(systemName: "info")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(backdropColor.contrastForeground)
                    .frame(width: 52, height: 52)
                    .background(backdropColor.contrastCircleBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(hasBio ? 1 : 0.4)
            .disabled(!hasBio)
            .accessibilityLabel("About")

            Button {
                onPlay?()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(backdropColor)
                    .frame(width: 62, height: 62)
                    .background(backdropColor.contrastForeground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play")

            Button {
                onShuffle?()
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(backdropColor.contrastForeground)
                    .frame(width: 52, height: 52)
                    .background(backdropColor.contrastCircleBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

/// Artist photo drawn behind the list. Pinned to the top of the screen, zooms on overscroll,
/// parallaxes at half speed and blurs out as the page scrolls.
private struct ArtistHeroPhotoView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(NetworkStatus.self) private var network

    let artist: PlexMetadata
    let heroHeight: CGFloat
    let backdropColor: Color
    let scrollOffset: CGFloat
    @Binding var isHidden: Bool

    @State private var image: UIImage?

    /// Height of the fade/blur band. It is anchored to the bottom edge of the hero row (where the
    /// artist name and buttons sit), not to the photo, so it stays behind them while the photo
    /// parallaxes.
    private let bandHeight: CGFloat = 190

    var body: some View {
        GeometryReader { geo in
            let stretch = max(-scrollOffset, 0)
            let scrolled = max(scrollOffset, 0)
            // Photo scrolls at half speed so the title and controls glide over it.
            let parallax = scrolled * 0.5
            // Photo blurs out as the title nears the top safe area.
            let blurProgress = min(max((scrolled - heroHeight * 0.4) / (heroHeight * 0.35), 0), 1)
            let scrollBlur = blurProgress * 30
            // On-screen bottom edge of the hero row.
            let rowBottom = max(heroHeight - scrollOffset, 0)
            let width = geo.size.width

            if !isHidden {
                ZStack(alignment: .top) {
                    transformedPhoto(width: width, blur: scrollBlur, stretch: stretch, parallax: parallax)

                    // Progressive blur behind the title and controls.
                    transformedPhoto(width: width, blur: 30, stretch: stretch, parallax: parallax)
                        .mask(alignment: .top) {
                            band(rowBottom: rowBottom) {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .black.opacity(0.7), location: 0.35),
                                        .init(color: .black, location: 0.6)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                        }

                    // Melt into the backdrop color.
                    band(rowBottom: rowBottom) {
                        LinearGradient(
                            stops: [
                                .init(color: backdropColor.opacity(0), location: 0),
                                .init(color: backdropColor.opacity(0.3), location: 0.3),
                                .init(color: backdropColor.opacity(0.7), location: 0.6),
                                .init(color: backdropColor.opacity(0.92), location: 0.85),
                                .init(color: backdropColor, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .frame(width: width, height: geo.size.height, alignment: .top)
                // Never paint below the hero row's current bottom edge.
                .mask(alignment: .top) {
                    Rectangle()
                        .frame(height: rowBottom)
                }
            }
        }
        .task(id: artist.thumb) {
            await loadImage()
        }
    }

    /// Places `content` in a band of `bandHeight` that ends at the hero row's bottom edge.
    private func band(rowBottom: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(height: bandHeight)
            .offset(y: rowBottom - bandHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func transformedPhoto(width: CGFloat, blur: CGFloat, stretch: CGFloat, parallax: CGFloat) -> some View {
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
        .frame(width: width, height: heroHeight, alignment: .top)
        .blur(radius: blur, opaque: true)
        .clipped()
        // Zoom from the first point of overscroll, pinned to the top edge.
        .scaleEffect(1 + stretch / max(heroHeight, 1), anchor: .top)
        .offset(y: -parallax)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

private extension View {
    /// Hairline border matching the album details artwork (no shadow).
    func artworkBorder(cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        )
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
