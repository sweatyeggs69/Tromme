import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayerService.self) private var player

    let playlist: PlexPlaylist

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var isDeletingPlaylist = false
    @State private var showDeletePlaylistConfirmation = false
    @State private var playlistDeleteErrorMessage: String?
    private let previewTracks: [PlexMetadata]?
    private let isPreviewMode: Bool

    private var artworkPath: String? {
        playlist.thumb ?? playlist.composite
    }

    private var playlistItemRequestKey: String {
        playlist.key ?? playlist.ratingKey
    }

    private var artworkColor: Color {
        ArtworkColorCache.shared.color(for: artworkPath) ?? .gray
    }

    private var titleColor: Color {
        artworkColor.isLightColor ? .black : .white
    }

    private var tertiaryTextColor: Color {
        titleColor.opacity(0.65)
    }

    private var iconForegroundColor: Color {
        artworkColor.isLightColor ? .black : .white
    }

    private var controlShadowColor: Color {
        artworkColor.isLightColor ? Color.black.opacity(0.22) : Color.white.opacity(0.18)
    }

    private var controlsDisabled: Bool {
        tracks.isEmpty
    }

    private var canDeletePlaylist: Bool {
        !isPreviewMode
    }

    private var playlistFooterRight: String {
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

    init(playlist: PlexPlaylist, previewTracks: [PlexMetadata]? = nil) {
        self.playlist = playlist
        self.previewTracks = previewTracks
        self.isPreviewMode = previewTracks != nil
        _tracks = State(initialValue: previewTracks ?? [])
        _isLoading = State(initialValue: previewTracks == nil)
    }

    private var playlistHeader: some View {
        VStack(spacing: 12) {
            ArtworkView(thumbPath: artworkPath, size: 300, cornerRadius: 8)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.top, 12)

            Text(playlist.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if let count = playlist.leafCount {
                Text("\(count) songs")
                    .font(.caption)
                    .foregroundStyle(tertiaryTextColor)
            }

            HStack(spacing: 14) {
                Button {
                    guard !controlsDisabled else { return }
                    var shuffled = tracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled)
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
                    player.play(tracks: tracks)
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
                        playPlaylistNext()
                    }
                    Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        addPlaylistToQueueEnd()
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

    private var trackListRows: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRowView(
                        track: track,
                        tracks: tracks,
                        index: index,
                        showArtwork: true,
                        showArtist: true,
                        showTrackNumber: false
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(titleColor.opacity(0.22))
                }
            }
        }
    }

    private var playlistFooter: some View {
        HStack {
            Spacer()
            Text(playlistFooterRight)
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
                            playlistHeader
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

                        playlistFooter
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                } else {
                    List {
                        Section {
                            playlistHeader
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden, edges: .top)
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(titleColor.opacity(0.22))
                                .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + 20 }
                                .listRowBackground(Color.clear)

                            trackListRows

                            playlistFooter
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canDeletePlaylist {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                            showDeletePlaylistConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                    .disabled(isDeletingPlaylist)
                }
            }
        }
        .alert("Delete Playlist?", isPresented: $showDeletePlaylistConfirmation) {
            Button("Delete Playlist", role: .destructive) {
                Task { await deletePlaylist() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \"\(playlist.title)\".")
        }
        .alert("Unable to Delete Playlist", isPresented: .init(
            get: { playlistDeleteErrorMessage != nil },
            set: { if !$0 { playlistDeleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playlistDeleteErrorMessage ?? "")
        }
        .task(id: artworkPath) {
            guard !isPreviewMode else { return }
            guard let server = serverConnection.currentServer else { return }
            await ArtworkColorCache.shared.resolveColor(
                for: artworkPath,
                using: client,
                server: server
            )
        }
        .task {
            guard !isPreviewMode else { return }
            await loadTracks()
        }
    }

    private func playPlaylistNext() {
        guard !tracks.isEmpty else { return }
        for track in tracks.reversed() {
            player.addToQueue(track)
        }
    }

    private func addPlaylistToQueueEnd() {
        guard !tracks.isEmpty else { return }
        for track in tracks {
            player.addToEndOfQueue(track)
        }
    }

    private func loadTracks() async {
        guard let server = serverConnection.currentServer else { return }
        do {
            tracks = try await client.cachedPlaylistItems(server: server, playlistKey: playlistItemRequestKey)
        } catch {
            tracks = []
        }
        isLoading = false
    }

    @MainActor
    private func deletePlaylist() async {
        guard let server = serverConnection.currentServer else { return }
        guard !isDeletingPlaylist else { return }

        isDeletingPlaylist = true
        defer { isDeletingPlaylist = false }

        do {
            try await client.deletePlaylist(server: server, playlistId: playlist.ratingKey)
            await LibraryCache.shared.remove(forKey: CacheKey.playlists(serverId: server.machineIdentifier))
            await LibraryCache.shared.remove(forKey: CacheKey.playlistItems(playlistKey: playlist.ratingKey))
            if let key = playlist.key {
                await LibraryCache.shared.remove(forKey: CacheKey.playlistItems(playlistKey: key))
            }
            dismiss()
        } catch {
            playlistDeleteErrorMessage = error.localizedDescription
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

#if DEBUG
#Preview {
    NavigationStack {
        PlaylistDetailView(
            playlist: DevelopmentMockData.previewPlaylist,
            previewTracks: DevelopmentMockData.previewPlaylistTracks
        )
    }
    .environment(AudioPlayerService())
}
#endif
