import SwiftUI

struct AlbumDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    let album: PlexMetadata
    @State private var albumDetails: PlexMetadata
    @State private var tracks: [PlexMetadata]
    @State private var firstTrackDetails: PlexMetadata?
    @State private var isLoadingTracks: Bool

    private var thumbPath: String? {
        album.thumb
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

    private var controlsDisabled: Bool {
        tracks.isEmpty
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

    private var albumHeader: some View {
        VStack {
            ArtworkView(thumbPath: album.thumb, size: 300, cornerRadius: 8)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.top, 12)

            Text(album.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 20)

            if let artistTarget = artistNavigationTarget {
                NavigationLink(value: artistTarget) {
                    Text(artistTarget.title)
                        .font(.title3)
                        .foregroundStyle(secondaryTextColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
            } else if let artist = album.parentTitle, !artist.isEmpty {
                Text(artist)
                    .font(.title3)
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            if let infoLine = albumInfoLine {
                Text(infoLine)
                    .font(.caption)
                    .foregroundStyle(tertiaryTextColor)
                    .multilineTextAlignment(.center)
                    .padding(.top, 0.5)
                    .padding(.horizontal, 20)
            }

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
                    .font(.title3.weight(.semibold))
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
        .frame(maxWidth: .infinity)
    }

    private let isPreviewMode: Bool

    init(album: PlexMetadata, previewTracks: [PlexMetadata]? = nil) {
        self.album = album
        _albumDetails = State(initialValue: album)
        _tracks = State(initialValue: previewTracks ?? [])
        _isLoadingTracks = State(initialValue: previewTracks == nil)
        self.isPreviewMode = previewTracks != nil
    }

    @MainActor
    private func loadAlbumDetails() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            albumDetails = try await client.cachedMetadata(server: server, ratingKey: album.ratingKey) ?? album
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
                        player: player,
                        tertiaryTextColor: tertiaryTextColor,
                        titleColor: titleColor
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(titleColor.opacity(0.22))
                }
            }
        }
    }

    private var albumFooter: some View {
        HStack {
            if let studio = albumDetails.studio {
                Text(studio)
            }

            Spacer()

            Text(albumFooterRight)
        }
        .font(.caption2)
        .foregroundStyle(tertiaryTextColor)
    }

    var body: some View {
        GeometryReader { geo in
            let isPadLandscape = UIDevice.current.userInterfaceIdiom == .pad && geo.size.width > geo.size.height

            ZStack {
                artworkColor
                    .ignoresSafeArea()

                if isPadLandscape {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            albumHeader
                                .padding(.bottom, 20)
                                .frame(width: geo.size.width * 0.4)

                            List {
                                Section {
                                    trackListRows
                                }
                            }
                            .scrollContentBackground(.hidden)
                            .listStyle(.plain)
                            .frame(width: geo.size.width * 0.6)
                        }

                        albumFooter
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                } else {
                    List {
                        Section {
                            albumHeader
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
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.58
    }
}

private struct AlbumTrackRow: View {
    let track: PlexMetadata
    let index: Int
    let tracks: [PlexMetadata]
    let player: AudioPlayerService
    let tertiaryTextColor: Color
    let titleColor: Color

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

                    Text(track.title)
                        .foregroundStyle(titleColor)
                        .lineLimit(1)

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
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tertiaryTextColor)
                    .frame(width: 28, height: 28)
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AlbumDetailView(
            album: DevelopmentMockData.recentAlbums.first ?? PlexMetadata(
                ratingKey: "album-1", key: nil, type: "album", subtype: nil, title: "Album",
                titleSort: nil, originalTitle: nil, summary: nil, studio: nil, year: nil,
                index: nil, parentIndex: nil, duration: nil, addedAt: nil,
                updatedAt: nil, viewCount: nil, lastViewedAt: nil, userRating: nil,
                thumb: nil, art: nil, parentThumb: nil, grandparentThumb: nil,
                grandparentArt: nil, parentTitle: "Preview Artist",
                grandparentTitle: nil, parentRatingKey: nil,
                grandparentRatingKey: nil, leafCount: nil, viewedLeafCount: nil,
                media: nil, genre: nil, style: nil, country: nil,
                subformat: nil, originallyAvailableAt: nil
            ),
            previewTracks: DevelopmentMockData.recentTracks
        )
    }
    .environment(AudioPlayerService())
}
#endif
