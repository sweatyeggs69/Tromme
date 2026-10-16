import Foundation
import SwiftUI

struct AlbumDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(NetworkStatus.self) private var network
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let album: PlexMetadata
    let sourceArtistRatingKey: String?
    @State private var viewModel: AlbumDetailViewModel
    @State private var selectedArtist: PlexMetadata?
    @State private var selectedMoreByAlbum: PlexMetadata?
    @State private var showsAllRecommendedAlbums = false
    @State private var addToPlaylistRequest: AddToPlaylistRequest?
    @State private var addToPlaylistResultMessage: String?
    @State private var showsAlbumInfoSheet = false
    @State private var showDeleteAlbumConfirmation = false
    @State private var showingChangeArtworkSheet = false
    @AppStorage("showPopularTracks") private var showPopularTracks = true
    @AppStorage(AnimatedArtworkEntitlement.settingKey) private var animatedArtworkEnabled = true

    // Read-only views of the view model's state, so the body reads as before.
    private var albumDetails: PlexMetadata { viewModel.albumDetails }
    private var tracks: [PlexMetadata] { viewModel.tracks }
    private var firstTrackDetails: PlexMetadata? { viewModel.firstTrackDetails }
    private var isLoadingTracks: Bool { viewModel.isLoadingTracks }
    private var artistAlbums: [PlexMetadata] { viewModel.artistAlbums }
    private var recommendedAlbums: [PlexMetadata] { viewModel.recommendedAlbums }
    private var popularTrackTitles: Set<String> { viewModel.popularTrackTitles }
    private var isDeletingAlbum: Bool { viewModel.isDeletingAlbum }
    private var isPreviewMode: Bool { viewModel.isPreviewMode }
    private var artistNavigationTarget: PlexMetadata? { viewModel.artistNavigationTarget }

    private var loadContext: AlbumDetailViewModel.Context {
        AlbumDetailViewModel.Context(
            server: serverConnection.currentServer,
            sectionId: serverConnection.currentLibrarySectionId,
            client: client,
            isConnected: network.isConnected,
            downloadManager: downloadManager,
            showPopularTracks: showPopularTracks
        )
    }

    private var thumbPath: String? {
        albumDetails.thumb ?? album.thumb
    }

    private var artworkColor: Color {
        ArtworkColorCache.shared.color(for: thumbPath, colorScheme: colorScheme, style: .cover) ?? .gray
    }

    private var titleColor: Color {
        artworkColor.contrastForeground
    }

    private var secondaryTextColor: Color {
        titleColor.opacity(0.85)
    }

    private var tertiaryTextColor: Color {
        titleColor.opacity(0.75)
    }

    private var bioTextColor: Color {
        titleColor.opacity(0.9)
    }

    private var controlForegroundColor: Color {
        artworkColor.contrastControlForeground
    }

    private var controlBackgroundColor: Color {
        artworkColor.contrastControlBackground
    }

    private var iconForegroundColor: Color {
        artworkColor.contrastForeground
    }


    private var controlsDisabled: Bool {
        tracks.isEmpty
    }

    @ViewBuilder
    private var albumDownloadButton: some View {
        let allDownloaded = !tracks.isEmpty && tracks.allSatisfy { downloadManager.isDownloaded($0.ratingKey) }
        let anyActive = tracks.contains { downloadManager.transientStates[$0.ratingKey] != nil }
        if allDownloaded {
            Button("Remove Downloads", systemImage: "arrow.down.circle.fill", role: .destructive) {
                for track in tracks { downloadManager.deleteDownload(ratingKey: track.ratingKey) }
            }
        } else {
            Button {
                guard let server = serverConnection.currentServer else { return }
                downloadManager.downloadBatch(tracks: tracks, server: server, client: client)
            } label: {
                Label(anyActive ? "Downloading…" : "Download Album", systemImage: anyActive ? "arrow.down.circle" : "arrow.down.circle")
            }
            .disabled(anyActive || tracks.isEmpty)
        }
    }

    private var moreByArtistAlbums: [PlexMetadata] {
        artistAlbums.filter { $0.ratingKey != album.ratingKey }
    }

    private var albumFooterRight: String {
        var parts: [String] = []
        let count = tracks.count
        if count > 0 {
            parts.append("\(count) \(count == 1 ? "song" : "songs")")
        }
        let totalMs = tracks.compactMap(\.duration).reduce(0, +)
        if totalMs > 0 {
            let totalSeconds = totalMs / 1000
            let minutes = totalSeconds / 60
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if hours > 0 {
                parts.append("\(hours) hr \(remainingMinutes) min")
            } else {
                parts.append("\(minutes) min")
            }
        }
        return parts.joined(separator: ", ")
    }

    private var releaseDateText: String? {
        let dateString = albumDetails.originallyAvailableAt ?? album.originallyAvailableAt
        guard let dateString, !dateString.isEmpty else { return nil }

        let components = dateString.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return dateString }

        var dateComponents = DateComponents()
        dateComponents.year = components[0]
        dateComponents.month = components[1]
        dateComponents.day = components[2]

        guard let date = Calendar.current.date(from: dateComponents) else { return dateString }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    private var labelLine: String? {
        var parts: [String] = []
        if let year = albumDetails.year ?? album.year {
            parts.append(String(year))
        }
        if let studio = albumDetails.studio, !studio.isEmpty {
            parts.append(studio)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var albumInfoLine: String? {
        var components: [String] = []

        if let genre = albumDetails.genre?.first?.tag, !genre.isEmpty {
            components.append(genre)
        }

        if let year = albumDetails.year {
            components.append(String(year))
        }

        if !isLosslessAlbumFormat, let plexStyle = plexAudioStyleText {
            components.append(plexStyle)
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    @ViewBuilder
    private func albumInfoLineView(centered: Bool = true) -> some View {
        let alignment: TextAlignment = centered ? .center : .leading
        let dimColor = tertiaryTextColor
        if isLosslessAlbumFormat {
            if let line = albumInfoLine {
                Text("\(line) · \(Image(systemName: "waveform.mid")) Lossless")
                    .font(.caption)
                    .foregroundStyle(dimColor)
                    .multilineTextAlignment(alignment)
            } else {
                Text("\(Image(systemName: "waveform.mid")) Lossless")
                    .font(.caption)
                    .foregroundStyle(dimColor)
                    .multilineTextAlignment(alignment)
            }
        } else if let line = albumInfoLine {
            Text(line)
                .font(.caption)
                .foregroundStyle(dimColor)
                .multilineTextAlignment(alignment)
        }
    }

    private var albumInfoText: String {
        let summary = (albumDetails.summary ?? album.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return summary
        }
        return "No album info available for this release."
    }

    private var bioText: String? {
        let summary = (albumDetails.summary ?? album.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    @ViewBuilder
    private var albumBioPreview: some View {
        if let bioText {
            Button {
                showsAlbumInfoSheet = true
            } label: {
                Text(bioText)
                    .font(.subheadline)
                    .foregroundStyle(bioTextColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private var shouldPopToSourceArtist: Bool {
        guard let sourceArtistRatingKey, let artistTarget = artistNavigationTarget else { return false }
        return sourceArtistRatingKey == artistTarget.ratingKey
    }

    private var isLosslessAlbumFormat: Bool {
        let media = firstTrackDetails?.media?.first
            ?? tracks.compactMap(\.media?.first).first
            ?? albumDetails.media?.first
            ?? album.media?.first
        let audioStream = media?.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })
        let codec = (audioStream?.codec ?? media?.audioCodec)?.lowercased()
        return codec == "flac" || codec == "alac"
    }

    private var plexAudioStyleText: String? {
        let media = firstTrackDetails?.media?.first
            ?? tracks.compactMap(\.media?.first).first
            ?? albumDetails.media?.first
            ?? album.media?.first
        guard let media else { return nil }

        let audioStream = media.part?
            .flatMap { $0.stream ?? [] }
            .first(where: { $0.streamType == 2 })

        let codec = (audioStream?.codec ?? media.audioCodec)?.uppercased()
        let bitrateText = (audioStream?.bitrate ?? media.bitrate).map { "\($0) kbps" }

        let parts = [codec, bitrateText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    @ViewBuilder
    private func centeredArtistHeaderText(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.title3)
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Tromme+ animated artwork, fading in over the static header artwork when the
    /// album has it.
    private var animatedArtworkOverlay: some View {
        AnimatedArtworkView(
            url: animatedArtworkEnabled ? viewModel.animatedArtworkURL : nil,
            cornerRadius: AppStyle.Radius.card
        )
    }

    private func albumHeader(width: CGFloat) -> some View {
        VStack {
            ArtworkView(
                thumbPath: thumbPath,
                size: AppStyle.Artwork.portraitHeader(forWidth: width),
                cornerRadius: AppStyle.Radius.card
            )
                // Shadow goes on the static artwork only, so the video overlay doesn't cast a second one.
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .overlay { animatedArtworkOverlay }
                .artworkBorder()
                .changeArtworkOnLongPress(isEnabled: !isPreviewMode) { showingChangeArtworkSheet = true }
                .padding(.top, 12)

            Text(album.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 20)

            if let artistTarget = artistNavigationTarget {
                if shouldPopToSourceArtist {
                    Button {
                        dismiss()
                    } label: {
                        centeredArtistHeaderText(artistTarget.title)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Button {
                        selectedArtist = artistTarget
                    } label: {
                        centeredArtistHeaderText(artistTarget.title)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if let artist = album.parentTitle, !artist.isEmpty {
                centeredArtistHeaderText(artist)
            }

            albumInfoLineView(centered: true)
                .padding(.top, 0.5)
                .padding(.horizontal, 20)

            albumActionButtons(bottomPadding: bioText != nil ? 4 : 20)

            albumBioPreview
                .padding(.top, 4)
                .padding(.bottom, 20)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
    }

    private func albumActionButtons(bottomPadding: CGFloat = 20) -> some View {
        ArtworkActionButtonsRow(
            artworkColor: artworkColor,
            isDisabled: controlsDisabled,
            bottomPadding: bottomPadding,
            onShuffle: {
                guard !controlsDisabled else { return }
                var shuffled = tracks
                shuffled.shuffle()
                player.play(tracks: shuffled, startingAt: 0)
            },
            onPlay: {
                guard !controlsDisabled else { return }
                player.play(tracks: tracks, startingAt: 0)
            },
            menuContent: {
                Button("Play Next", systemImage: "text.insert") {
                    playAlbumNext()
                }
                Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    addAlbumToQueueEnd()
                }
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    presentAddToPlaylist(for: tracks.map(\.ratingKey))
                }
            }
        )
    }


    init(
        album: PlexMetadata,
        sourceArtistRatingKey: String? = nil,
        previewTracks: [PlexMetadata]? = nil,
        previewArtistAlbums: [PlexMetadata] = [],
        previewRecommendedAlbums: [PlexMetadata] = []
    ) {
        self.album = album
        self.sourceArtistRatingKey = sourceArtistRatingKey
        _viewModel = State(initialValue: AlbumDetailViewModel(
            album: album,
            previewTracks: previewTracks,
            previewArtistAlbums: previewArtistAlbums,
            previewRecommendedAlbums: previewRecommendedAlbums
        ))
    }

    private func playAlbumNext() {
        guard !tracks.isEmpty else { return }
        for track in tracks.reversed() {
            player.addToQueue(track)
        }
    }

    private func addAlbumToQueueEnd() {
        guard !tracks.isEmpty else { return }
        for track in tracks {
            player.addToEndOfQueue(track)
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var albumGridColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: AppStyle.ArtistDetailAlbumGrid.itemSpacing), count: count)
    }

    private var hasMultipleDiscs: Bool {
        guard tracks.count > 1 else { return false }
        return Set(tracks.map { $0.parentIndex ?? 1 }).count > 1
    }

    private var tracksByDisc: [(discNumber: Int, tracks: [(globalIndex: Int, track: PlexMetadata)])] {
        var discMap: [Int: [(globalIndex: Int, track: PlexMetadata)]] = [:]
        for (i, track) in tracks.enumerated() {
            let disc = track.parentIndex ?? 1
            discMap[disc, default: []].append((globalIndex: i, track: track))
        }
        return discMap.keys.sorted().map { disc in
            (discNumber: disc, tracks: discMap[disc]!)
        }
    }

    @ViewBuilder
    private func discHeaderRow(_ discNumber: Int) -> some View {
        Text("Disc \(discNumber)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tertiaryTextColor)
            .listRowBackground(artworkColor)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 4, trailing: 20))
    }

    private func trackRow(track: PlexMetadata, globalIndex: Int, isLandscape: Bool = false) -> some View {
        AlbumTrackRow(
            track: track,
            index: globalIndex,
            tracks: tracks,
            albumArtistName: albumDetails.parentTitle ?? album.parentTitle,
            player: player,
            tertiaryTextColor: tertiaryTextColor,
            titleColor: titleColor,
            isPopular: popularTrackTitles.contains(track.title),
            isLandscape: isLandscape,
            onAddToPlaylist: { track in
                presentAddToPlaylist(for: [track.ratingKey])
            },
            onDelete: { deletedTrack in
                viewModel.removeTrack(deletedTrack)
            }
        )
        .listRowBackground(artworkColor)
        .listRowSeparatorTint(titleColor.opacity(0.22))
    }

    private func trackListRows(isLandscape: Bool = false) -> some View {
        Group {
            if isLoadingTracks {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(artworkColor)
            } else if hasMultipleDiscs {
                ForEach(tracksByDisc, id: \.discNumber) { group in
                    discHeaderRow(group.discNumber)
                    ForEach(group.tracks, id: \.globalIndex) { item in
                        trackRow(track: item.track, globalIndex: item.globalIndex, isLandscape: isLandscape)
                    }
                }
            } else {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    trackRow(track: track, globalIndex: index, isLandscape: isLandscape)
                }
            }
        }
    }

    @ViewBuilder
    private var landscapeAlbumTitleAndArtist: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(album.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(titleColor)
                .lineLimit(2)

            if let artistTarget = artistNavigationTarget {
                if shouldPopToSourceArtist {
                    Button {
                        dismiss()
                    } label: {
                        Text(artistTarget.title)
                            .font(.title3)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        selectedArtist = artistTarget
                    } label: {
                        Text(artistTarget.title)
                            .font(.title3)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                }
            } else if let artist = album.parentTitle, !artist.isEmpty {
                Text(artist)
                    .font(.title3)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            albumInfoLineView(centered: false)
                .padding(.top, 4)

            albumBioPreview
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var landscapeHeader: some View {
        HStack(alignment: .bottom, spacing: 20) {
            ArtworkView(thumbPath: thumbPath, size: AppStyle.Artwork.header, cornerRadius: AppStyle.Radius.card)
                // Shadow goes on the static artwork only, so the video overlay doesn't cast a second one.
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .overlay { animatedArtworkOverlay }
                .artworkBorder()
                .changeArtworkOnLongPress(isEnabled: !isPreviewMode) { showingChangeArtworkSheet = true }
                .frame(width: AppStyle.Artwork.header)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                landscapeAlbumTitleAndArtist

                albumActionButtons()
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
        }
        .padding(.top, 96)
        .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
    }

    private var albumFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let releaseDateText {
                Text(releaseDateText)
            }

            if !albumFooterRight.isEmpty {
                Text(albumFooterRight)
            }

            if let labelLine {
                Text(labelLine)
            }
        }
        .font(.caption)
        .foregroundStyle(tertiaryTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func albumSectionHeader(_ title: String) -> some View {
        albumSectionHeader(title, showsDisclosure: false) {}
    }

    private func albumSectionHeader(
        _ title: String,
        showsDisclosure: Bool,
        disclosureAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)

            if showsDisclosure {
                Button(action: disclosureAction) {
                    Image(systemName: "chevron.right")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(secondaryTextColor)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all \(title)")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 20, leading: AppStyle.Spacing.pageHorizontal, bottom: 8, trailing: AppStyle.Spacing.pageHorizontal))
            .listRowBackground(artworkColor)
            .listRowSeparator(.hidden)
    }

    private func albumRail(_ albums: [PlexMetadata]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(albums) { album in
                    Button {
                        selectedMoreByAlbum = album
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ArtworkView(
                                thumbPath: album.thumb,
                                size: AppStyle.Artwork.card,
                                cornerRadius: AppStyle.Radius.card
                            )

                            Text(album.title)
                                .font(AppStyle.Typography.itemTitle)
                                .foregroundStyle(titleColor)
                                .lineLimit(1)

                            HStack(spacing: 4) {
                                Text(album.releaseYear)
                                if let format = album.formatLabel {
                                    Text("·")
                                    Text(format)
                                }
                            }
                            .font(AppStyle.Typography.itemSubtitle)
                            .foregroundStyle(tertiaryTextColor)
                            .lineLimit(1)
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
        .padding(.bottom, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(artworkColor)
        .listRowSeparator(.hidden)
    }

    var body: some View {
        GeometryReader { geo in
            let usesSideBySideHeader = UIDevice.current.userInterfaceIdiom == .pad

            ZStack {
                artworkColor
                    .ignoresSafeArea()

                if usesSideBySideHeader {
                    List {
                        landscapeHeader
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(artworkColor)

                        trackListRows(isLandscape: true)

                        albumFooter
                            .listRowBackground(artworkColor)
                            .listRowSeparator(.hidden)

                        if artistAlbums.count > 1,
                           !moreByArtistAlbums.isEmpty,
                           let artistName = artistNavigationTarget?.title {
                            albumSectionHeader("More By \(artistName)")
                            albumRail(moreByArtistAlbums)
                        }

                        if !recommendedAlbums.isEmpty {
                            albumSectionHeader(
                                "You Might Also Like",
                                showsDisclosure: true
                            ) {
                                showsAllRecommendedAlbums = true
                            }
                            albumRail(Array(recommendedAlbums.prefix(8)))
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(artworkColor)
                    .listStyle(.plain)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .scrollEdgeEffectHidden(true, for: .top)
                    .ignoresSafeArea(edges: .top)
                } else {
                    List {
                        Section {
                            albumHeader(width: geo.size.width)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden, edges: .top)
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(titleColor.opacity(0.22))
                                .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + 20 }
                                .listRowBackground(artworkColor)

                            trackListRows()

                            albumFooter
                                .listRowBackground(artworkColor)
                                .listRowSeparator(.hidden)

                            if artistAlbums.count > 1,
                               !moreByArtistAlbums.isEmpty,
                               let artistName = artistNavigationTarget?.title {
                                albumSectionHeader("More By \(artistName)")
                                albumRail(moreByArtistAlbums)
                            }

                            if !recommendedAlbums.isEmpty {
                                albumSectionHeader(
                                    "You Might Also Like",
                                    showsDisclosure: true
                                ) {
                                    showsAllRecommendedAlbums = true
                                }
                                albumRail(Array(recommendedAlbums.prefix(8)))
                            }

                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(artworkColor)
                    .listStyle(.plain)
                    .scrollEdgeEffectHidden(true, for: .top)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist)
        }
        .navigationDestination(item: $selectedMoreByAlbum) { album in
            AlbumDetailView(
                album: album,
                sourceArtistRatingKey: albumDetails.parentRatingKey ?? self.album.parentRatingKey
            )
        }
        .navigationDestination(isPresented: $showsAllRecommendedAlbums) {
            AlbumRecommendationGridView(
                title: "You Might Also Like",
                albums: recommendedAlbums
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !isPreviewMode {
                        albumDownloadButton
                        Divider()
                        Button("Delete Album", systemImage: "trash", role: .destructive) {
                            showDeleteAlbumConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(.primary)
                .disabled(isDeletingAlbum)
            }
        }
        .task(id: thumbPath) {
            guard !isPreviewMode else { return }
            guard let server = serverConnection.currentServer else { return }
            await ArtworkColorCache.shared.resolveColor(
                for: thumbPath,
                using: client,
                server: server,
                style: .cover
            )
        }
        .task(id: album.ratingKey) {
            await viewModel.load(loadContext)
        }
        .task(id: "\(album.ratingKey)|\(animatedArtworkEnabled)") {
            await viewModel.loadAnimatedArtwork()
        }
        .sheet(isPresented: $showsAlbumInfoSheet) {
            NavigationStack {
                ScrollView {
                    Text(albumInfoText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .navigationTitle("Album Info")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $addToPlaylistRequest) { request in
            AddToPlaylistSheet(itemRatingKeys: request.itemRatingKeys) { playlistCount in
                let itemCount = request.itemRatingKeys.count
                let itemLabel = itemCount == 1 ? "item" : "items"
                let playlistLabel = playlistCount == 1 ? "playlist" : "playlists"
                addToPlaylistResultMessage = "Added \(itemCount) \(itemLabel) to \(playlistCount) \(playlistLabel)."
            }
        }
        .sheet(isPresented: $showingChangeArtworkSheet) {
            ChangeArtworkSheet(
                ratingKey: album.ratingKey,
                subject: "album"
            ) {
                await viewModel.loadAlbumDetails(loadContext)
                player.updateAlbumThumb(albumRatingKey: album.ratingKey, newThumb: albumDetails.thumb)
            }
        }
        .alert("Added to Playlist", isPresented: .init(
            get: { addToPlaylistResultMessage != nil },
            set: { if !$0 { addToPlaylistResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addToPlaylistResultMessage ?? "")
        }
        .alert("Delete Album?", isPresented: $showDeleteAlbumConfirmation) {
            Button("Delete Album", role: .destructive) {
                Task {
                    if await viewModel.deleteAlbum(loadContext) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \"\(album.title)\".")
        }
        .alert("Unable to Delete Album", isPresented: .init(
            get: { viewModel.albumDeleteErrorMessage != nil },
            set: { if !$0 { viewModel.albumDeleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.albumDeleteErrorMessage ?? "")
        }
    }

    private func presentAddToPlaylist(for itemKeys: [String]) {
        let normalizedKeys = orderedUnique(keys: itemKeys)
        guard !normalizedKeys.isEmpty else { return }
        addToPlaylistRequest = AddToPlaylistRequest(itemRatingKeys: normalizedKeys)
    }

    private func orderedUnique(keys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in keys where !key.isEmpty {
            if seen.insert(key).inserted {
                result.append(key)
            }
        }
        return result
    }

}

#if DEBUG
#Preview("iPad Landscape", traits: .landscapeLeft) {
    let album = DevelopmentMockData.artistAlbums[0]
    NavigationStack {
        AlbumDetailView(
            album: album,
            previewTracks: DevelopmentMockData.artistAllTracks.filter { $0.parentRatingKey == album.ratingKey },
            previewArtistAlbums: DevelopmentMockData.artistAlbums,
            previewRecommendedAlbums: DevelopmentMockData.recommendationAlbums
        )
    }
    .environment(AudioPlayerService())
    .environment(DownloadManager())
    .environment(NetworkStatus.shared)
}

#Preview("iPad Portrait", traits: .portrait) {
    let album = DevelopmentMockData.artistAlbums[0]
    NavigationStack {
        AlbumDetailView(
            album: album,
            previewTracks: DevelopmentMockData.artistAllTracks.filter { $0.parentRatingKey == album.ratingKey },
            previewArtistAlbums: DevelopmentMockData.artistAlbums,
            previewRecommendedAlbums: DevelopmentMockData.recommendationAlbums
        )
    }
    .environment(AudioPlayerService())
    .environment(DownloadManager())
    .environment(NetworkStatus.shared)
}
#endif
