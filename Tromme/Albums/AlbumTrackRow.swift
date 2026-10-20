import Foundation
import SwiftUI

struct AlbumTrackRow: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(DownloadManager.self) private var downloadManager

    let track: PlexMetadata
    let index: Int
    let tracks: [PlexMetadata]
    let albumArtistName: String?
    let player: AudioPlayerService
    let tertiaryTextColor: Color
    let titleColor: Color
    var isPopular: Bool = false
    var isLandscape: Bool = false
    let onAddToPlaylist: (PlexMetadata) -> Void
    let onDelete: (PlexMetadata) -> Void
    let onEdited: (PlexMetadata) -> Void

    @State private var favoriteOverride: Double? = nil
    @State private var isRating = false
    @State private var showDeleteTrackConfirmation = false
    @State private var trackDeleteErrorMessage: String?
    @State private var isDeletingTrack = false
    @State private var metadataRequest: MetadataSheetRequest?

    @ViewBuilder
    private var trackDownloadButton: some View {
        let isDownloaded = downloadManager.isDownloaded(track.ratingKey)
        let isActive = downloadManager.transientStates[track.ratingKey] != nil
        if isDownloaded {
            Button("Remove Download", systemImage: "arrow.down.circle.fill", role: .destructive) {
                downloadManager.deleteDownload(ratingKey: track.ratingKey)
            }
        } else {
            Button(isActive ? "Downloading…" : "Download", systemImage: "arrow.down.circle") {
                guard let server = serverConnection.currentServer else { return }
                downloadManager.download(track: track, server: server, client: client)
            }
            .disabled(isActive)
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
        isRating = true
        Task {
            let success = await player.setFavorited(!removing, for: track, server: server, client: client, sectionId: sectionId)
            if !success { favoriteOverride = previous }
            isRating = false
        }
    }

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
                HStack(spacing: 4) {
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
                    .frame(width: 22, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if isPopular {
                                Image(systemName: "flame.fill")
                                    .font(.caption)
                                    .foregroundStyle(tertiaryTextColor)
                            }
                            Text(track.title)
                                .foregroundStyle(titleColor)
                                .lineLimit(1)
                        }

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

            if isFavorited {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(tertiaryTextColor)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if !track.durationFormatted.isEmpty {
                Text(track.durationFormatted)
                    .font(isLandscape ? .footnote : AppStyle.Typography.itemSubtitle)
                    .foregroundStyle(tertiaryTextColor)
            }

            Menu {
                Button(isFavorited ? "Unfavorite" : "Favorite", systemImage: isFavorited ? "star.fill" : "star") {
                    toggleFavorite()
                }
                .disabled(isRating)

                Divider()

                Button("Play Next", systemImage: "text.insert") {
                    player.addToQueue(track)
                }
                Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.addToEndOfQueue(track)
                }
                Button("Add to Playlist", systemImage: "text.badge.plus") {
                    onAddToPlaylist(track)
                }

                Divider()
                trackDownloadButton

                Divider()

Button("Edit Track", systemImage: "pencil") {
                    metadataRequest = .edit(track)
                }
                .disabled(serverConnection.currentServer == nil)
                Button("Track Info", systemImage: "info.circle") {
                    metadataRequest = .trackInfo(track)
                }

                Divider()

                Button("Delete Track", systemImage: "trash", role: .destructive) {
                    showDeleteTrackConfirmation = true
                }
                .disabled(isDeletingTrack || serverConnection.currentServer == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tertiaryTextColor)
                    .frame(width: 28, height: 28)
            }
        }
        .contextMenu {
            Button(isFavorited ? "Unfavorite" : "Favorite", systemImage: isFavorited ? "star.fill" : "star") {
                toggleFavorite()
            }
            .disabled(isRating)

            Divider()

            Button("Play Next", systemImage: "text.insert") {
                player.addToQueue(track)
            }
            Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.addToEndOfQueue(track)
            }
            Button("Add to Playlist", systemImage: "text.badge.plus") {
                onAddToPlaylist(track)
            }
            trackDownloadButton

            Divider()

            Button("Edit Track", systemImage: "pencil") {
                metadataRequest = .edit(track)
            }
            .disabled(serverConnection.currentServer == nil)
            Button("Track Info", systemImage: "info.circle") {
                metadataRequest = .trackInfo(track)
            }

            Divider()

            Button("Delete Track", systemImage: "trash", role: .destructive) {
                showDeleteTrackConfirmation = true
            }
            .disabled(isDeletingTrack || serverConnection.currentServer == nil)
        }
        .metadataSheets(request: $metadataRequest) { fresh in
            player.updateTrack(fresh)
            onEdited(fresh)
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

    @MainActor
    private func deleteTrack() async {
        guard let server = serverConnection.currentServer else { return }
        guard !isDeletingTrack else { return }

        isDeletingTrack = true
        defer { isDeletingTrack = false }

        do {
            try await client.deleteLibraryItem(server: server, ratingKey: track.ratingKey)
            downloadManager.deleteDownload(ratingKey: track.ratingKey)
            await LibraryStore.shared.remove(ratingKey: track.ratingKey, serverId: server.machineIdentifier)
            if let sectionId = serverConnection.currentLibrarySectionId {
                Task { await client.smartRefresh(server: server, sectionId: sectionId) }
            }
            onDelete(track)
        } catch {
            trackDeleteErrorMessage = error.localizedDescription
        }
    }
}
