import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloadManager

    let playlist: PlexPlaylist

    @State private var tracks: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var trackNavigationTarget: PlexMetadata? = nil
    @State private var isDeletingPlaylist = false
    @State private var showDeletePlaylistConfirmation = false
    @State private var playlistDeleteErrorMessage: String?
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var displayTitle: String
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
        artworkColor.isLightColor() ? .black : .white
    }

    private var tertiaryTextColor: Color {
        titleColor.opacity(0.75)
    }

    private var iconForegroundColor: Color {
        artworkColor.isLightColor() ? .black : .white
    }

    private var controlShadowColor: Color {
        artworkColor.isLightColor() ? Color.black.opacity(0.22) : Color.white.opacity(0.18)
    }

    private var controlsDisabled: Bool {
        tracks.isEmpty
    }

    @ViewBuilder
    private var playlistDownloadButton: some View {
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
                Label(anyActive ? "Downloading…" : "Download Playlist", systemImage: "arrow.down.circle")
            }
            .disabled(anyActive || tracks.isEmpty)
        }
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
        _displayTitle = State(initialValue: playlist.title)
    }

    private func playlistActionButtons(bottomPadding: CGFloat = 20) -> some View {
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
                    .background(Circle().fill(artworkColor.isLightColor() ? Color.black.opacity(0.12) : Color.white.opacity(0.15)))
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
                .font(.body.weight(.semibold))
                .foregroundStyle(artworkColor)
                .padding(.horizontal, 50)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(artworkColor.isLightColor() ? Color.black : Color.white)
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
                    .background(Circle().fill(artworkColor.isLightColor() ? Color.black.opacity(0.12) : Color.white.opacity(0.15)))
                    .shadow(color: controlShadowColor, radius: 6, y: -2)
            }
            .disabled(controlsDisabled)
            .opacity(controlsDisabled ? 0.45 : 1.0)
        }
        .padding(.top, 6)
        .padding(.bottom, bottomPadding)
    }

    private var playlistHeader: some View {
        VStack {
            ArtworkView(thumbPath: artworkPath, size: 300, cornerRadius: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.top, 12)

            Text(displayTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 20)

            playlistActionButtons()
        }
        .frame(maxWidth: .infinity)
    }

    private var landscapePlaylistHeader: some View {
        HStack(alignment: .bottom, spacing: 20) {
            ArtworkView(thumbPath: artworkPath, size: 300, cornerRadius: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .frame(width: 300)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                Text(displayTitle)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                playlistActionButtons()
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
        }
        .padding(.top, 96)
        .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
    }

    /// Smart playlists are rule-generated by Plex and don't support manual ordering.
    private var canReorderPlaylist: Bool {
        !isPreviewMode && !(playlist.smart ?? false)
    }

    private var trackListRows: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(artworkColor)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRowView(
                        track: track,
                        tracks: tracks,
                        index: index,
                        showArtwork: true,
                        showArtist: true,
                        showTrackNumber: false,
                        showDuration: true,
                        artworkSize: AppStyle.TrackList.browseArtworkSize,
                        artworkCornerRadius: AppStyle.TrackList.artworkCornerRadius,
                        onNavigate: { trackNavigationTarget = $0 }
                    )
                    .listRowInsets(AppStyle.TrackList.rowInsets)
                    .listRowBackground(artworkColor)
                    .listRowSeparatorTint(titleColor.opacity(0.22))
                }
                .onMove(perform: moveTracks)
                .moveDisabled(!canReorderPlaylist)
            }
        }
    }

    private var playlistFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !playlistFooterRight.isEmpty {
                Text(playlistFooterRight)
            }
        }
        .font(.caption)
        .foregroundStyle(tertiaryTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        GeometryReader { geo in
            let usesSideBySideHeader = UIDevice.current.userInterfaceIdiom == .pad

            ZStack {
                artworkColor
                    .ignoresSafeArea()

                if usesSideBySideHeader {
                    List {
                        landscapePlaylistHeader
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(artworkColor)

                        trackListRows

                        playlistFooter
                            .listRowBackground(artworkColor)
                            .listRowSeparator(.hidden)
                    }
                    .scrollContentBackground(.hidden)
                    .background(artworkColor)
                    .listStyle(.plain)
                    .listRowSpacing(AppStyle.TrackList.rowSpacing)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .scrollEdgeEffectHidden(true, for: .top)
                    .ignoresSafeArea(edges: .top)
                } else {
                    List {
                        Section {
                            playlistHeader
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden, edges: .top)
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(titleColor.opacity(0.22))
                                .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + 20 }
                                .listRowBackground(artworkColor)

                            trackListRows

                            playlistFooter
                                .listRowBackground(artworkColor)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(artworkColor)
                    .listStyle(.plain)
                    .listRowSpacing(AppStyle.TrackList.rowSpacing)
                    .scrollEdgeEffectHidden(true, for: .top)
                }
            }
        }
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
                Menu {
                    playlistDownloadButton
                    if canDeletePlaylist {
                        Divider()
                        Button("Rename", systemImage: "pencil") {
                            renameText = displayTitle
                            showRenameAlert = true
                        }
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                            showDeletePlaylistConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(.primary)
                .disabled(isDeletingPlaylist)
            }
        }
        .alert("Delete Playlist?", isPresented: $showDeletePlaylistConfirmation) {
            Button("Delete Playlist", role: .destructive) {
                Task { await deletePlaylist() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \"\(displayTitle)\".")
        }
        .alert("Unable to Delete Playlist", isPresented: .init(
            get: { playlistDeleteErrorMessage != nil },
            set: { if !$0 { playlistDeleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playlistDeleteErrorMessage ?? "")
        }
        .alert("Rename Playlist", isPresented: $showRenameAlert) {
            TextField("Playlist name", text: $renameText)
            Button("Save") {
                Task { await performRename() }
            }
            Button("Cancel", role: .cancel) {}
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

        // Pre-populate from memory cache synchronously (no actor hop needed).
        // Eliminates the spinner flash when the memory cache is warm.
        let cacheKey = CacheKey.playlistItems(playlistKey: playlistItemRequestKey)
        if let cached = LibraryCache.shared.memoryCached([PlexMetadata].self, forKey: cacheKey), !cached.isEmpty {
            tracks = cached
            isLoading = false
        }

        do {
            tracks = try await client.cachedPlaylistItems(server: server, playlistKey: playlistItemRequestKey)
        } catch {
            if tracks.isEmpty { tracks = [] }
        }
        isLoading = false
    }

    private func moveTracks(from source: IndexSet, to destination: Int) {
        let previousTracks = tracks
        let movedIDs = Set(source.map { tracks[$0].id })
        tracks.move(fromOffsets: source, toOffset: destination)
        let movedInNewOrder = tracks.enumerated().filter { movedIDs.contains($0.element.id) }
        Task { await persistReorder(movedInNewOrder: movedInNewOrder, previousTracks: previousTracks) }
    }

    @MainActor
    private func persistReorder(
        movedInNewOrder: [(offset: Int, element: PlexMetadata)],
        previousTracks: [PlexMetadata]
    ) async {
        guard let server = serverConnection.currentServer else { return }
        do {
            for (offset, track) in movedInNewOrder {
                guard let itemID = track.playlistItemID else { continue }
                let afterTrack = offset > 0 ? tracks[offset - 1] : nil
                try await client.movePlaylistItem(
                    server: server,
                    playlistId: playlist.ratingKey,
                    playlistItemID: itemID,
                    afterPlaylistItemID: afterTrack?.playlistItemID
                )
            }
            await LibraryCache.shared.remove(forKey: CacheKey.playlistItems(playlistKey: playlistItemRequestKey))
        } catch {
            tracks = previousTracks
        }
    }

    @MainActor
    private func performRename() async {
        guard let server = serverConnection.currentServer else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayTitle else { return }
        do {
            try await client.renamePlaylist(server: server, playlistId: playlist.ratingKey, newTitle: trimmed)
            displayTitle = trimmed
            await LibraryCache.shared.remove(forKey: CacheKey.playlists(serverId: server.machineIdentifier))
        } catch {
            // silently fail — displayTitle remains unchanged
        }
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

#if DEBUG
#Preview {
    NavigationStack {
        PlaylistDetailView(
            playlist: DevelopmentMockData.previewPlaylist,
            previewTracks: DevelopmentMockData.previewPlaylistTracks
        )
    }
    .environment(AudioPlayerService())
    .environment(DownloadManager())
}
#endif
