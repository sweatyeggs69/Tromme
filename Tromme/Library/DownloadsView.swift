import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("autoDownloadEnabled") private var autoDownloadEnabled = false
    @AppStorage("autoDownloadMode") private var autoDownloadMode = AutoDownloadMode.defaultMode.rawValue
    @State private var showDeleteAllConfirmation = false
    @State private var isStartingDownloads = false

    var body: some View {
        let tracks = downloadManager.downloadedTracksSorted
        List {
            if !tracks.isEmpty {
                Section {
                    ForEach(tracks) { record in
                        trackRow(record, allTracks: tracks)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            downloadManager.deleteDownload(ratingKey: tracks[index].ratingKey)
                        }
                    }
                } header: {
                    Text(storageText(tracks: tracks))
                }
            }
        }
        .navigationTitle("Downloads")
        .overlay {
            if tracks.isEmpty {
                if downloadManager.pendingDownloadCount > 0 {
                    ContentUnavailableView(
                        "Downloading",
                        systemImage: "arrow.down.circle",
                        description: Text("\(downloadManager.pendingDownloadCount) \(downloadManager.pendingDownloadCount == 1 ? "song" : "songs") remaining")
                    )
                } else {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Songs you download will appear here for offline listening.")
                    )
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if autoDownloadEnabled, autoDownloadMode == AutoDownloadMode.library.rawValue {
                    if downloadManager.hasActiveDownloads {
                        Button {
                            downloadManager.cancelAllPendingDownloads()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .tint(.primary)
                    } else {
                        Button {
                            Task { await startAutoDownload() }
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .tint(.primary)
                        .disabled(isStartingDownloads)
                    }
                }
                if !tracks.isEmpty {
                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .alert("Delete All Downloads?", isPresented: $showDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                downloadManager.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all downloaded songs from your device.")
        }
    }

    private func startAutoDownload() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        isStartingDownloads = true
        if let tracks = try? await client.cachedTracks(server: server, sectionId: sectionId) {
            downloadManager.resumeAutoDownload(tracks: tracks, server: server, client: client)
        }
        isStartingDownloads = false
    }

    private func storageText(tracks: [DownloadedTrackRecord]) -> String {
        let bytes = downloadManager.totalStorageUsed
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let base = "\(tracks.count) \(tracks.count == 1 ? "song" : "songs") · \(formatted)"
        let remaining = downloadManager.pendingDownloadCount
        return remaining > 0 ? "\(base) · \(remaining) remaining" : base
    }

    @ViewBuilder
    private func trackRow(_ record: DownloadedTrackRecord, allTracks: [DownloadedTrackRecord]) -> some View {
        let isCurrentTrack = player.currentTrack?.ratingKey == record.ratingKey
        Button {
            let allTracks = allTracks.map { $0.asPlexMetadata() }
            let startIndex = allTracks.firstIndex(where: { $0.ratingKey == record.ratingKey }) ?? 0
            player.play(tracks: allTracks, startingAt: startIndex)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(isCurrentTrack ? AppStyle.Colors.tint : .primary)
                    Text("\(record.artistName) — \(record.albumName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.down.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(AppStyle.Colors.tint.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                downloadManager.deleteDownload(ratingKey: record.ratingKey)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

#Preview {
    NavigationStack {
        DownloadsView()
            .environment(DownloadManager())
            .environment(AudioPlayerService())
    }
}
