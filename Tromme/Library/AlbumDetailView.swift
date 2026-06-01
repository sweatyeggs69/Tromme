import Foundation
import SwiftUI

struct AlbumDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    let album: PlexMetadata
    let sourceArtistRatingKey: String?
    @State private var albumDetails: PlexMetadata
    @State private var tracks: [PlexMetadata]
    @State private var firstTrackDetails: PlexMetadata?
    @State private var isLoadingTracks: Bool
    @State private var selectedArtist: PlexMetadata?
    @State private var selectedMoreByAlbum: PlexMetadata?
    @State private var artistAlbums: [PlexMetadata]
    @State private var addToPlaylistItemKeys: [String] = []
    @State private var showingAddToPlaylistSheet = false
    @State private var addToPlaylistResultMessage: String?
    @State private var showsAlbumInfoSheet = false
    @State private var showDeleteAlbumConfirmation = false
    @State private var albumDeleteErrorMessage: String?
    @State private var isDeletingAlbum = false
    @State private var showingChangeArtworkSheet = false

    private var thumbPath: String? {
        albumDetails.thumb ?? album.thumb
    }

    private var artworkColor: Color {
        ArtworkColorCache.shared.color(for: thumbPath) ?? .gray
    }

    private var titleColor: Color {
        artworkColor.isLightColor ? .black : .white
    }

    private var secondaryTextColor: Color {
        titleColor.opacity(0.78)
    }

    private var tertiaryTextColor: Color {
        titleColor.opacity(0.65)
    }

    private var controlForegroundColor: Color {
        artworkColor.isLightColor ? .white : .black
    }

    private var controlBackgroundColor: Color {
        artworkColor.isLightColor ? Color.black.opacity(0.75) : Color.white.opacity(0.82)
    }

    private var controlShadowColor: Color {
        artworkColor.isLightColor ? Color.black.opacity(0.22) : Color.white.opacity(0.18)
    }

    private var iconForegroundColor: Color {
        artworkColor.isLightColor ? .black : .white
    }

    private var moreBySectionBackgroundColor: Color {
        .black.opacity(0.08)
    }

    private var controlsDisabled: Bool {
        tracks.isEmpty
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

        if let plexStyle = plexAudioStyleText {
            components.append(plexStyle)
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private var albumInfoText: String {
        let summary = (albumDetails.summary ?? album.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return summary
        }
        return "No album info available for this release."
    }

    private var artistNavigationTarget: PlexMetadata? {
        let artistTitle = albumDetails.parentTitle ?? album.parentTitle
        let artistRatingKey = albumDetails.parentRatingKey ?? album.parentRatingKey
        guard let artistTitle, !artistTitle.isEmpty,
              let artistRatingKey, !artistRatingKey.isEmpty else { return nil }

        return PlexMetadata(
            ratingKey: artistRatingKey,
            title: artistTitle,
            type: "artist",
            thumb: albumDetails.parentThumb ?? album.parentThumb
        )
    }

    private var shouldPopToSourceArtist: Bool {
        guard let sourceArtistRatingKey, let artistTarget = artistNavigationTarget else { return false }
        return sourceArtistRatingKey == artistTarget.ratingKey
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

    private func albumHeader(
        includesTitleAndArtist: Bool = true,
        includesInfoLine: Bool = true
    ) -> some View {
        VStack {
            ArtworkView(thumbPath: thumbPath, size: 300, cornerRadius: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.top, 12)

            if includesTitleAndArtist {
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
            }

            if includesInfoLine, let infoLine = albumInfoLine {
                Text(infoLine)
                    .font(.caption)
                    .foregroundStyle(tertiaryTextColor)
                    .multilineTextAlignment(.center)
                    .padding(.top, 0.5)
                    .padding(.horizontal, 20)
            }

            albumActionButtons
        }
        .frame(maxWidth: .infinity)
    }

    private var albumActionButtons: some View {
        HStack(spacing: 14) {
            Button {
                guard !controlsDisabled else { return }
                var shuffled = tracks
                shuffled.shuffle()
                player.play(tracks: shuffled, startingAt: 0)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(iconForegroundColor)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(artworkColor.isLightColor ? Color.black.opacity(0.12) : Color.white.opacity(0.15)))
                    .shadow(color: controlShadowColor, radius: 6, y: -2)
            }
            .buttonStyle(.plain)
            .disabled(controlsDisabled)
            .opacity(controlsDisabled ? 0.45 : 1.0)

            Button {
                guard !controlsDisabled else { return }
                player.play(tracks: tracks, startingAt: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(artworkColor)
                .padding(.horizontal, 56)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(artworkColor.isLightColor ? Color.black : Color.white)
                )
            }
            .buttonStyle(.plain)
            .disabled(controlsDisabled)
            .opacity(controlsDisabled ? 0.45 : 1.0)

            Menu {
                Button("Play Next", systemImage: "text.insert") {
                    playAlbumNext()
                }
                Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    addAlbumToQueueEnd()
                }
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    presentAddToPlaylist(for: tracks.map(\.ratingKey))
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(iconForegroundColor)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(artworkColor.isLightColor ? Color.black.opacity(0.12) : Color.white.opacity(0.15)))
                    .shadow(color: controlShadowColor, radius: 6, y: -2)
            }
            .disabled(controlsDisabled)
            .opacity(controlsDisabled ? 0.45 : 1.0)
        }
        .padding(.top, 6)
        .padding(.bottom, 20)
    }

    private let isPreviewMode: Bool

    init(
        album: PlexMetadata,
        sourceArtistRatingKey: String? = nil,
        previewTracks: [PlexMetadata]? = nil,
        previewArtistAlbums: [PlexMetadata] = []
    ) {
        self.album = album
        self.sourceArtistRatingKey = sourceArtistRatingKey
        _albumDetails = State(initialValue: album)
        _tracks = State(initialValue: previewTracks ?? [])
        _artistAlbums = State(initialValue: previewArtistAlbums)
        _isLoadingTracks = State(initialValue: previewTracks == nil)
        self.isPreviewMode = previewTracks != nil
    }

    @MainActor
    private func loadAlbumDetails() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            albumDetails = try await client.cachedAlbumMetadata(server: server, ratingKey: album.ratingKey) ?? album
        } catch {
            albumDetails = album
        }
    }

    @MainActor
    private func loadTracks() async {
        guard let server = serverConnection.currentServer else {
            isLoadingTracks = false
            return
        }
        do {
            tracks = try await client.cachedChildren(server: server, ratingKey: album.ratingKey)
            if let firstTrack = tracks.first {
                firstTrackDetails = try await client.cachedMetadata(server: server, ratingKey: firstTrack.ratingKey)
            } else {
                firstTrackDetails = nil
            }
        } catch {
            tracks = []
            firstTrackDetails = nil
        }
        isLoadingTracks = false
    }

    @MainActor
    private func loadArtistAlbums() async {
        guard let server = serverConnection.currentServer,
              let artistKey = (albumDetails.parentRatingKey ?? album.parentRatingKey),
              !artistKey.isEmpty else { return }

        do {
            artistAlbums = try await client.cachedChildren(server: server, ratingKey: artistKey)
                .sorted {
                    let date0 = $0.originallyAvailableAt ?? ""
                    let date1 = $1.originallyAvailableAt ?? ""
                    if date0 != date1 { return date0 > date1 }
                    if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) > ($1.year ?? 0) }
                    return ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title)
                }
        } catch {
            artistAlbums = []
        }
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

    private var trackListRows: some View {
        Group {
            if isLoadingTracks {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    AlbumTrackRow(
                        track: track,
                        index: index,
                        tracks: tracks,
                        albumArtistName: albumDetails.parentTitle ?? album.parentTitle,
                        player: player,
                        tertiaryTextColor: tertiaryTextColor,
                        titleColor: titleColor,
                        onAddToPlaylist: { track in
                            presentAddToPlaylist(for: [track.ratingKey])
                        }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(titleColor.opacity(0.22))
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(titleColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 20, leading: AppStyle.Spacing.pageHorizontal, bottom: 8, trailing: AppStyle.Spacing.pageHorizontal))
            .listRowBackground(moreBySectionBackgroundColor)
            .listRowSeparator(.hidden)
    }

    private func moreByArtistGrid(_ albums: [PlexMetadata]) -> some View {
        LazyVGrid(columns: albumGridColumns, spacing: AppStyle.ArtistDetailAlbumGrid.rowSpacing) {
            ForEach(albums) { album in
                Button {
                    selectedMoreByAlbum = album
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
                            .font(AppStyle.Typography.itemTitle)
                            .foregroundStyle(titleColor)
                            .lineLimit(1)

                        Text(album.releaseYear)
                            .font(AppStyle.Typography.itemSubtitle)
                            .foregroundStyle(tertiaryTextColor)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: AppStyle.Spacing.pageHorizontal, bottom: 0, trailing: AppStyle.Spacing.pageHorizontal))
        .listRowBackground(moreBySectionBackgroundColor)
        .listRowSeparator(.hidden)
    }

    var body: some View {
        GeometryReader { geo in
            let isPadLandscape = UIDevice.current.userInterfaceIdiom == .pad && geo.size.width > geo.size.height

            ZStack {
                artworkColor
                    .ignoresSafeArea()

                if isPadLandscape {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ArtworkView(thumbPath: thumbPath, size: 300, cornerRadius: 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                                .padding(.top, 12)

                            albumActionButtons
                                .padding(.top, 16)

                            if let infoLine = albumInfoLine {
                                Text(infoLine)
                                    .font(.caption)
                                    .foregroundStyle(tertiaryTextColor)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                            }
                        }
                        .padding(.bottom, 20)
                        .frame(width: geo.size.width * 0.33)

                        VStack(alignment: .leading, spacing: 0) {
                            landscapeAlbumTitleAndArtist
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                .padding(.bottom, 18)

                            List {
                                Section {
                                    trackListRows

                                    albumFooter
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)

                                    if artistAlbums.count > 1,
                                       !moreByArtistAlbums.isEmpty,
                                       let artistName = artistNavigationTarget?.title {
                                        albumSectionHeader("More By \(artistName)")
                                        moreByArtistGrid(moreByArtistAlbums)
                                    }
                                }
                            }
                            .scrollContentBackground(.hidden)
                            .listStyle(.plain)
                        }
                        .frame(width: geo.size.width * 0.67)
                    }
                } else {
                    List {
                        Section {
                            albumHeader()
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden, edges: .top)
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(titleColor.opacity(0.22))
                                .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + 20 }
                                .listRowBackground(Color.clear)

                            trackListRows

                            albumFooter
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)

                            if artistAlbums.count > 1,
                               !moreByArtistAlbums.isEmpty,
                               let artistName = artistNavigationTarget?.title {
                                albumSectionHeader("More By \(artistName)")
                                moreByArtistGrid(moreByArtistAlbums)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showsAlbumInfoSheet = true
                    } label: {
                        Label("Album Info", systemImage: "info.circle")
                    }
                    if !isPreviewMode {
                        Button {
                            showingChangeArtworkSheet = true
                        } label: {
                            Label("Change Artwork", systemImage: "photo")
                        }
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
                server: server
            )
        }
        .task {
            guard !isPreviewMode else { return }
            async let detailsTask: Void = loadAlbumDetails()
            async let tracksTask: Void = loadTracks()
            _ = await (detailsTask, tracksTask)
            await loadArtistAlbums()
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
        .sheet(isPresented: $showingAddToPlaylistSheet) {
            AddToPlaylistSheet(itemRatingKeys: addToPlaylistItemKeys) { playlistCount in
                let itemCount = addToPlaylistItemKeys.count
                let itemLabel = itemCount == 1 ? "item" : "items"
                let playlistLabel = playlistCount == 1 ? "playlist" : "playlists"
                addToPlaylistResultMessage = "Added \(itemCount) \(itemLabel) to \(playlistCount) \(playlistLabel)."
            }
        }
        .sheet(isPresented: $showingChangeArtworkSheet) {
            ChangeAlbumArtworkSheet(
                albumRatingKey: album.ratingKey
            ) {
                await loadAlbumDetails()
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
                Task { await deleteAlbum() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \"\(album.title)\".")
        }
        .alert("Unable to Delete Album", isPresented: .init(
            get: { albumDeleteErrorMessage != nil },
            set: { if !$0 { albumDeleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(albumDeleteErrorMessage ?? "")
        }
    }

    private func presentAddToPlaylist(for itemKeys: [String]) {
        let normalizedKeys = orderedUnique(keys: itemKeys)
        guard !normalizedKeys.isEmpty else { return }
        addToPlaylistItemKeys = normalizedKeys
        showingAddToPlaylistSheet = true
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

    @MainActor
    private func deleteAlbum() async {
        guard !isPreviewMode else { return }
        guard let server = serverConnection.currentServer else { return }
        guard !isDeletingAlbum else { return }

        isDeletingAlbum = true
        defer { isDeletingAlbum = false }

        do {
            try await client.deleteLibraryItem(server: server, ratingKey: album.ratingKey)
            await LibraryCache.shared.clearAll()
            await ImageCache.shared.clearAll()
            dismiss()
        } catch {
            albumDeleteErrorMessage = error.localizedDescription
        }
    }
}

private extension Color {
    var isLightColor: Bool {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }

        // WCAG relative luminance for contrast-based black/white foreground choice.
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? (component / 12.92) : pow((component + 0.055) / 1.055, 2.4)
        }

        let luminance =
            (0.2126 * linearized(red)) +
            (0.7152 * linearized(green)) +
            (0.0722 * linearized(blue))

        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        let contrastDelta = abs(blackContrast - whiteContrast)

        // Dead-band: when both options are close, bias to a slightly lighter threshold.
        if contrastDelta < 0.35 {
            return luminance > 0.45
        }
        return blackContrast >= whiteContrast
    }
}

private struct AlbumTrackRow: View {
    let track: PlexMetadata
    let index: Int
    let tracks: [PlexMetadata]
    let albumArtistName: String?
    let player: AudioPlayerService
    let tertiaryTextColor: Color
    let titleColor: Color
    let onAddToPlaylist: (PlexMetadata) -> Void

    private var trackArtistCredit: String {
        track.artistDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var alternateArtistText: String? {
        let albumArtist = (albumArtistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trackArtist = trackArtistCredit
        guard !trackArtist.isEmpty else { return nil }

        // Rule: if track artist differs from album artist, show track artist.
        if albumArtist.isEmpty { return trackArtist }
        let hasDifferentArtist = trackArtist.caseInsensitiveCompare(albumArtist) != .orderedSame

        guard hasDifferentArtist else { return nil }
        return trackArtist
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks: tracks, startingAt: index)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        if player.currentTrack?.ratingKey == track.ratingKey && player.isPlaying {
                            NowPlayingBarsView(color: tertiaryTextColor)
                                .frame(width: 22, height: 14)
                        } else {
                            Text("\(track.index ?? (index + 1))")
                                .font(.body)
                                .foregroundStyle(tertiaryTextColor)
                        }
                    }
                    .frame(width: 22, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .foregroundStyle(titleColor)
                            .lineLimit(1)

                        if let alternateArtistText {
                            Text(alternateArtistText)
                                .font(.caption)
                                .foregroundStyle(tertiaryTextColor)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Play Next", systemImage: "text.insert") {
                    player.addToQueue(track)
                }
                Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.addToEndOfQueue(track)
                }
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    onAddToPlaylist(track)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tertiaryTextColor)
                    .frame(width: 28, height: 28)
            }
        }
        .contextMenu {
            Button("Play Next", systemImage: "text.insert") {
                player.addToQueue(track)
            }
            Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.addToEndOfQueue(track)
            }
            Button("Add to Playlist", systemImage: "text.badge.plus") {
                onAddToPlaylist(track)
            }
        }
    }
}

#if DEBUG
#Preview {
    let previewAlbum = PlexMetadata(
        ratingKey: "preview-album",
        key: nil,
        type: "album",
        subtype: nil,
        title: "Midnight Signals",
        titleSort: nil,
        originalTitle: nil,
        summary: "A preview album with release metadata for Canvas.",
        studio: "Tromme Records",
        year: 2026,
        index: nil,
        parentIndex: nil,
        duration: nil,
        addedAt: nil,
        updatedAt: nil,
        viewCount: nil,
        lastViewedAt: nil,
        userRating: nil,
        thumb: nil,
        art: nil,
        parentThumb: nil,
        grandparentThumb: nil,
        grandparentArt: nil,
        parentTitle: "The Canvas Band",
        grandparentTitle: nil,
        parentRatingKey: "preview-artist",
        grandparentRatingKey: nil,
        leafCount: 4,
        viewedLeafCount: nil,
        media: [
            PlexMedia(audioCodec: "flac", container: "flac")
        ],
        genre: [
            PlexTag(tag: "Alternative")
        ],
        style: nil,
        country: nil,
        subformat: nil,
        originallyAvailableAt: "2026-05-31"
    )

    let previewTracks = [
        PlexMetadata(
            ratingKey: "preview-track-1",
            key: nil,
            type: "track",
            subtype: nil,
            title: "Signal One",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            studio: nil,
            year: nil,
            index: 1,
            parentIndex: 1,
            duration: 214_000,
            addedAt: nil,
            updatedAt: nil,
            viewCount: nil,
            lastViewedAt: nil,
            userRating: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "Midnight Signals",
            grandparentTitle: "The Canvas Band",
            parentRatingKey: "preview-album",
            grandparentRatingKey: "preview-artist",
            leafCount: nil,
            viewedLeafCount: nil,
            media: nil,
            genre: nil,
            style: nil,
            country: nil,
            subformat: nil,
            originallyAvailableAt: nil
        ),
        PlexMetadata(
            ratingKey: "preview-track-2",
            key: nil,
            type: "track",
            subtype: nil,
            title: "Late Drive",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            studio: nil,
            year: nil,
            index: 2,
            parentIndex: 1,
            duration: 188_000,
            addedAt: nil,
            updatedAt: nil,
            viewCount: nil,
            lastViewedAt: nil,
            userRating: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "Midnight Signals",
            grandparentTitle: "The Canvas Band",
            parentRatingKey: "preview-album",
            grandparentRatingKey: "preview-artist",
            leafCount: nil,
            viewedLeafCount: nil,
            media: nil,
            genre: nil,
            style: nil,
            country: nil,
            subformat: nil,
            originallyAvailableAt: nil
        ),
        PlexMetadata(
            ratingKey: "preview-track-3",
            key: nil,
            type: "track",
            subtype: nil,
            title: "Soft Static",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            studio: nil,
            year: nil,
            index: 3,
            parentIndex: 1,
            duration: 246_000,
            addedAt: nil,
            updatedAt: nil,
            viewCount: nil,
            lastViewedAt: nil,
            userRating: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "Midnight Signals",
            grandparentTitle: "The Canvas Band",
            parentRatingKey: "preview-album",
            grandparentRatingKey: "preview-artist",
            leafCount: nil,
            viewedLeafCount: nil,
            media: nil,
            genre: nil,
            style: nil,
            country: nil,
            subformat: nil,
            originallyAvailableAt: nil
        ),
        PlexMetadata(
            ratingKey: "preview-track-4",
            key: nil,
            type: "track",
            subtype: nil,
            title: "Afterimage",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            studio: nil,
            year: nil,
            index: 4,
            parentIndex: 1,
            duration: 201_000,
            addedAt: nil,
            updatedAt: nil,
            viewCount: nil,
            lastViewedAt: nil,
            userRating: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "Midnight Signals",
            grandparentTitle: "The Canvas Band",
            parentRatingKey: "preview-album",
            grandparentRatingKey: "preview-artist",
            leafCount: nil,
            viewedLeafCount: nil,
            media: nil,
            genre: nil,
            style: nil,
            country: nil,
            subformat: nil,
            originallyAvailableAt: nil
        )
    ]

    let previewArtistAlbums = [
        previewAlbum,
        PlexMetadata(
            ratingKey: "preview-album-2",
            key: nil,
            type: "album",
            subtype: nil,
            title: "Glass Roads",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            studio: "Tromme Records",
            year: 2024,
            index: nil,
            parentIndex: nil,
            duration: nil,
            addedAt: nil,
            updatedAt: nil,
            viewCount: nil,
            lastViewedAt: nil,
            userRating: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "The Canvas Band",
            grandparentTitle: nil,
            parentRatingKey: "preview-artist",
            grandparentRatingKey: nil,
            leafCount: 10,
            viewedLeafCount: nil,
            media: nil,
            genre: nil,
            style: nil,
            country: nil,
            subformat: nil,
            originallyAvailableAt: "2024-09-13"
        ),
        PlexMetadata(
            ratingKey: "preview-album-3",
            key: nil,
            type: "album",
            subtype: nil,
            title: "North Terminal",
            titleSort: nil,
            originalTitle: nil,
            summary: nil,
            studio: "Tromme Records",
            year: 2022,
            index: nil,
            parentIndex: nil,
            duration: nil,
            addedAt: nil,
            updatedAt: nil,
            viewCount: nil,
            lastViewedAt: nil,
            userRating: nil,
            thumb: nil,
            art: nil,
            parentThumb: nil,
            grandparentThumb: nil,
            grandparentArt: nil,
            parentTitle: "The Canvas Band",
            grandparentTitle: nil,
            parentRatingKey: "preview-artist",
            grandparentRatingKey: nil,
            leafCount: 8,
            viewedLeafCount: nil,
            media: nil,
            genre: nil,
            style: nil,
            country: nil,
            subformat: nil,
            originallyAvailableAt: "2022-03-18"
        )
    ]

    NavigationStack {
        AlbumDetailView(
            album: previewAlbum,
            previewTracks: previewTracks,
            previewArtistAlbums: previewArtistAlbums
        )
    }
    .environment(AudioPlayerService())
}
#endif
