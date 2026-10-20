import SwiftUI

struct TrackRowView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.appAccentColor) private var appAccentColor

    let track: PlexMetadata
    let tracks: [PlexMetadata]
    let index: Int
    var showArtwork: Bool = false
    var showArtist: Bool = false
    var subtitle: String? = nil
    var showTrackNumber: Bool = true
    var showDuration: Bool = false
    var artworkSize: CGFloat = 42
    var artworkCornerRadius: CGFloat = 8
    var showsMenu: Bool = true
    var showFavoriteStar: Bool = true
    var isCompact: Bool = false
    var titleFont: Font? = nil
    var artistFont: Font? = nil
    var titleColorOverride: Color? = nil
    var secondaryColorOverride: Color? = nil
    var onNavigate: ((PlexMetadata) -> Void)? = nil
    @State private var showDeleteTrackConfirmation = false
    @State private var trackDeleteErrorMessage: String?
    @State private var isDeletingTrack = false
    @State private var addToPlaylistTrack: PlexMetadata? = nil
    @State private var favoriteOverride: Double? = nil
    @State private var isRating = false
    @State private var metadataRequest: MetadataSheetRequest?
    /// The track as re-read after an edit, so the row updates before its list reloads.
    @State private var editedTrack: PlexMetadata?

    private var shown: PlexMetadata { editedTrack ?? track }

    var body: some View {
        trackRow
            .contextMenu(isCompact ? nil : ContextMenu { trackContextMenu.tint(appAccentColor) })
        .metadataSheets(request: $metadataRequest) { fresh in
            editedTrack = fresh
            player.updateTrack(fresh)
        }
        .onChange(of: track) { editedTrack = nil }
        .sheet(item: $addToPlaylistTrack) { trackToAdd in
            AddToPlaylistSheet(itemRatingKeys: [trackToAdd.ratingKey])
        }
        .alert("Delete Track?", isPresented: $showDeleteTrackConfirmation) {
            Button("Delete Track", role: .destructive) {
                Task { await deleteTrack() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \"\(shown.title)\".")
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
        (favoriteOverride ?? shown.userRating ?? 0) >= 10
    }

    private func toggleFavorite() {
        guard let server = serverConnection.currentServer else { return }
        let sectionId = serverConnection.currentLibrarySectionId
        let previous = favoriteOverride ?? shown.userRating
        let removing = isFavorited
        favoriteOverride = removing ? 0 : 10
        isRating = true
        Task {
            let success = await player.setFavorited(!removing, for: track, server: server, client: client, sectionId: sectionId)
            if !success { favoriteOverride = previous }
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
            addToPlaylistTrack = shown
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }

        Button {
            metadataRequest = .trackInfo(shown)
        } label: {
            Label("Track Info", systemImage: "info.circle")
        }

        Divider()

        downloadMenuButton

        Divider()

        if let album = PlexMetadata.albumStub(from: shown) {
            Button {
                onNavigate?(album)
            } label: {
                Label("Go to Album", systemImage: "square.stack")
                Text(shown.parentTitle ?? "")
            }
        }

        if let artist = PlexMetadata.artistStub(from: shown) {
            Button {
                onNavigate?(artist)
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
                Text(shown.grandparentTitle ?? shown.artistName)
            }
        }

        Divider()

        Button {
            metadataRequest = .edit(shown)
        } label: {
            Label("Edit Track", systemImage: "pencil")
        }
        .disabled(serverConnection.currentServer == nil)

        Button("Delete Track", systemImage: "trash", role: .destructive) {
            showDeleteTrackConfirmation = true
        }
        .disabled(isDeletingTrack || serverConnection.currentServer == nil)
    }

    @ViewBuilder
    private var downloadMenuButton: some View {
        let isDownloaded = downloadManager.isDownloaded(shown.ratingKey)
        let isActive = downloadManager.transientStates[shown.ratingKey] != nil
        if isDownloaded {
            Button("Remove Download", systemImage: "arrow.down.circle.fill", role: .destructive) {
                downloadManager.deleteDownload(ratingKey: shown.ratingKey)
            }
        } else {
            Button {
                guard let server = serverConnection.currentServer else { return }
                downloadManager.download(track: track, server: server, client: client)
            } label: {
                switch downloadManager.transientStates[shown.ratingKey] {
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
        if let state = downloadManager.transientStates[shown.ratingKey] {
            Group {
                switch state {
                case .queued:
                    Image(systemName: "clock")
                        .foregroundStyle(secondaryColorOverride ?? Color.secondary)
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
        } else if downloadManager.isDownloaded(shown.ratingKey) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.subheadline)
                .foregroundStyle(secondaryColorOverride ?? Color.secondary)
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
                ArtworkView(thumbPath: shown.thumb ?? shown.parentThumb, size: artworkSize, cornerRadius: artworkCornerRadius)
            } else if showTrackNumber {
                ZStack {
                    if isCurrentTrack && player.isPlaying {
                        NowPlayingBarsView()
                            .frame(width: 24, height: 16)
                    } else {
                        Text("\(shown.index ?? (index + 1))")
                            .font(.body)
                            .monospacedDigit()
                            .foregroundStyle(isCurrentTrack ? AnyShapeStyle(.tint) : AnyShapeStyle(secondaryColorOverride ?? Color.secondary))
                    }
                }
                .frame(width: 28, alignment: .center)
            }

            VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
                Text(shown.title)
                    .font(titleFont ?? (isCompact ? .caption : .body))
                    .lineLimit(1)
                    .foregroundStyle(isCurrentTrack ? AnyShapeStyle(.tint) : AnyShapeStyle(titleColorOverride ?? Color.primary))

                if let subtitle {
                    Text(subtitle)
                        .font(artistFont ?? (isCompact ? .caption2 : .caption))
                        .foregroundStyle(secondaryColorOverride ?? Color.secondary)
                        .lineLimit(1)
                } else if showArtist {
                    Text(shown.artistDisplayName)
                        .font(artistFont ?? (isCompact ? .caption2 : .caption))
                        .foregroundStyle(secondaryColorOverride ?? Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isFavorited && showFavoriteStar {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(secondaryColorOverride ?? Color.secondary)
                    .frame(width: 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if showDuration, !shown.durationFormatted.isEmpty {
                Text(shown.durationFormatted)
                    .font(isCompact ? .caption2 : .caption)
                    .foregroundStyle(secondaryColorOverride ?? Color.secondary)
                    .monospacedDigit()
            }

            downloadStateIndicator

            if showsMenu {
                Menu {
                    trackContextMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(secondaryColorOverride ?? Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .tint(appAccentColor)
            }
        }
        .appPlainRowItemStyle()
        .frame(height: isCompact ? 44 : nil)
        .contentShape(Rectangle())
    }

    private var isCurrentTrack: Bool {
        player.currentTrack?.ratingKey == shown.ratingKey
    }

    @MainActor
    private func deleteTrack() async {
        guard let server = serverConnection.currentServer else { return }
        guard !isDeletingTrack else { return }

        isDeletingTrack = true
        defer { isDeletingTrack = false }

        do {
            try await client.deleteLibraryItem(server: server, ratingKey: shown.ratingKey)
            downloadManager.deleteDownload(ratingKey: shown.ratingKey)
            await LibraryStore.shared.remove(ratingKey: shown.ratingKey, serverId: server.machineIdentifier)
            if let sectionId = serverConnection.currentLibrarySectionId {
                Task { await client.smartRefresh(server: server, sectionId: sectionId) }
            }
        } catch {
            trackDeleteErrorMessage = error.localizedDescription
        }
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
