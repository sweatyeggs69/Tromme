import SwiftUI

struct TrackRowView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    let track: PlexMetadata
    let tracks: [PlexMetadata]
    let index: Int
    var showArtwork: Bool = false
    var showArtist: Bool = false
    var subtitle: String? = nil
    var showTrackNumber: Bool = true
    var artworkSize: CGFloat = 42
    var artworkCornerRadius: CGFloat = 8
    var showsMenu: Bool = true
    var showFavoriteStar: Bool = true
    var isCompact: Bool = false
    var titleFont: Font? = nil
    var artistFont: Font? = nil
    var onNavigate: ((PlexMetadata) -> Void)? = nil
    @State private var showDeleteTrackConfirmation = false
    @State private var trackDeleteErrorMessage: String?
    @State private var isDeletingTrack = false
    @State private var addToPlaylistTrack: PlexMetadata? = nil
    @State private var favoriteOverride: Double? = nil
    @State private var isRating = false

    var body: some View {
        trackRow
            .contextMenu(isCompact ? nil : ContextMenu { trackContextMenu })
        .sheet(item: $addToPlaylistTrack) { trackToAdd in
            AddToPlaylistSheet(itemRatingKeys: [trackToAdd.ratingKey])
        }
        .alert("Delete Track?", isPresented: $showDeleteTrackConfirmation) {
            Button("Delete Track", role: .destructive) {
                Task { await deleteTrack() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \"\(track.title)\".")
        }
        .alert("Unable to Delete Track", isPresented: .init(
            get: { trackDeleteErrorMessage != nil },
            set: { if !$0 { trackDeleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(trackDeleteErrorMessage ?? "")
        }
    }

    private var isFavorited: Bool {
        (favoriteOverride ?? track.userRating ?? 0) >= 10
    }

    private func toggleFavorite() {
        guard let server = serverConnection.currentServer else { return }
        let sectionId = serverConnection.currentLibrarySectionId
        let previous = favoriteOverride ?? track.userRating
        let removing = isFavorited
        favoriteOverride = removing ? 0 : 10
        let isCurrentTrack = track.ratingKey == player.currentTrack?.ratingKey
        if isCurrentTrack { player.updateCurrentTrackRating(removing ? 0 : 10) }
        isRating = true
        Task {
            do {
                try await client.rateItem(server: server, ratingKey: track.ratingKey, rating: removing ? -1 : 10)
                if let sectionId {
                    await LibraryCache.shared.remove(forKey: CacheKey.favoriteTracks(serverId: server.machineIdentifier, sectionId: sectionId))
                    await LibraryCache.shared.remove(forKey: CacheKey.homeFavorites(serverId: server.machineIdentifier, sectionId: sectionId))
                }
                NotificationCenter.default.post(name: .favoritesDidChange, object: nil)
            } catch {
                favoriteOverride = previous
                if isCurrentTrack { player.updateCurrentTrackRating(previous) }
            }
            isRating = false
        }
    }

    @ViewBuilder
    private var trackContextMenu: some View {
        Button {
            toggleFavorite()
        } label: {
            Label(isFavorited ? "Unfavorite" : "Favorite", systemImage: isFavorited ? "star.fill" : "star")
        }
        .disabled(isRating)

        Divider()

        Button {
            player.addToQueue(track)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            player.addToEndOfQueue(track)
        } label: {
            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
        }

        Button {
            addToPlaylistTrack = track
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Divider()

        downloadMenuButton

        Divider()

        if let album = PlexMetadata.albumStub(from: track) {
            Button {
                onNavigate?(album)
            } label: {
                Label("Go to Album", systemImage: "square.stack")
                Text(track.parentTitle ?? "")
            }
        }

        if let artist = PlexMetadata.artistStub(from: track) {
            Button {
                onNavigate?(artist)
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
                Text(track.grandparentTitle ?? track.artistName)
            }
        }

        Divider()

        Button("Delete Track", systemImage: "trash", role: .destructive) {
            showDeleteTrackConfirmation = true
        }
        .disabled(isDeletingTrack || serverConnection.currentServer == nil)
    }

    @ViewBuilder
    private var downloadMenuButton: some View {
        let isDownloaded = downloadManager.isDownloaded(track.ratingKey)
        let isActive = downloadManager.transientStates[track.ratingKey] != nil
        if isDownloaded {
            Button("Remove Download", systemImage: "arrow.down.circle.fill", role: .destructive) {
                downloadManager.deleteDownload(ratingKey: track.ratingKey)
            }
        } else {
            Button {
                guard let server = serverConnection.currentServer else { return }
                downloadManager.download(track: track, server: server, client: client)
            } label: {
                switch downloadManager.transientStates[track.ratingKey] {
                case .queued:
                    Label("Queued", systemImage: "clock")
                case .downloading:
                    Label("Downloading…", systemImage: "arrow.down.circle")
                case .failed:
                    Label("Retry Download", systemImage: "arrow.clockwise.circle")
                case nil:
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .disabled(isActive)
        }
    }

    @ViewBuilder
    private var downloadStateIndicator: some View {
        if let state = downloadManager.transientStates[track.ratingKey] {
            Group {
                switch state {
                case .queued:
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                case .downloading:
                    ProgressView()
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.subheadline)
            .frame(width: 22)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        } else if downloadManager.isDownloaded(track.ratingKey) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    private var trackRow: some View {
        Button {
            player.play(tracks: tracks, startingAt: index)
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(spacing: isCompact ? 8 : 10) {
            if showArtwork {
                ArtworkView(thumbPath: track.thumb ?? track.parentThumb, size: artworkSize, cornerRadius: artworkCornerRadius)
            } else if showTrackNumber {
                ZStack {
                    if isCurrentTrack && player.isPlaying {
                        NowPlayingBarsView()
                            .frame(width: 24, height: 16)
                    } else {
                        Text("\(track.index ?? (index + 1))")
                            .font(.body)
                            .monospacedDigit()
                            .foregroundStyle(isCurrentTrack ? AppStyle.Colors.tint : .secondary)
                    }
                }
                .frame(width: 28, alignment: .center)
            }

            VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
                Text(track.title)
                    .font(titleFont ?? (isCompact ? .caption : .body))
                    .lineLimit(1)
                    .foregroundStyle(isCurrentTrack ? AppStyle.Colors.tint : .primary)

                if let subtitle {
                    Text(subtitle)
                        .font(artistFont ?? (isCompact ? .caption2 : .caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if showArtist {
                    Text(track.artistDisplayName)
                        .font(artistFont ?? (isCompact ? .caption2 : .caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isFavorited && showFavoriteStar {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            downloadStateIndicator

            if showsMenu {
                Menu {
                    trackContextMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        .appPlainRowItemStyle()
        .frame(height: isCompact ? 44 : nil)
        .contentShape(Rectangle())
    }

    private var isCurrentTrack: Bool {
        player.currentTrack?.ratingKey == track.ratingKey
    }

    @MainActor
    private func deleteTrack() async {
        guard let server = serverConnection.currentServer else { return }
        guard !isDeletingTrack else { return }

        isDeletingTrack = true
        defer { isDeletingTrack = false }

        do {
            try await client.deleteLibraryItem(server: server, ratingKey: track.ratingKey)
            await LibraryCache.shared.clearAll()
            await ImageCache.shared.clearAll()
        } catch {
            trackDeleteErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Now Playing Bars Animation (Apple Music equalizer indicator)

struct NowPlayingBarsView: View {
    var color: Color = AppStyle.Colors.tint
    @State private var isAnimating = false
    /// Random heights and durations are computed once on appear and stable across re-renders.
    @State private var barHeights: [CGFloat] = [0.65, 0.85, 0.45, 0.75]
    @State private var barDurations: [Double] = [0.45, 0.38, 0.52, 0.41]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3)
                    .scaleEffect(y: isAnimating ? barHeights[index] : 0.4, anchor: .bottom)
                    .animation(
                        .easeInOut(duration: barDurations[index])
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            barHeights = (0..<4).map { _ in CGFloat.random(in: 0.3...1.0) }
            barDurations = (0..<4).map { _ in Double.random(in: 0.3...0.6) }
            isAnimating = true
        }
        .onDisappear { isAnimating = false }
    }
}

#Preview {
    let track = PlexMetadata(
        ratingKey: "1", key: nil, type: "track", subtype: nil, title: "Test Song",
        titleSort: nil, originalTitle: nil, summary: nil, year: nil,
        index: 1, parentIndex: nil, duration: 234000, addedAt: nil,
        updatedAt: nil, viewCount: nil, lastViewedAt: nil,
        thumb: nil, art: nil, parentThumb: nil, grandparentThumb: nil,
        grandparentArt: nil, parentTitle: "Test Album",
        grandparentTitle: "Test Artist", parentRatingKey: nil,
        grandparentRatingKey: nil, leafCount: nil, viewedLeafCount: nil,
        media: nil, genre: nil, style: nil, country: nil,
        subformat: nil, similar: nil, originallyAvailableAt: nil
    )
    TrackRowView(track: track, tracks: [track], index: 0)
        .environment(AudioPlayerService())
}
