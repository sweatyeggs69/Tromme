import SwiftUI

enum DownloadSortOrder: String, CaseIterable {
    case dateAdded = "Date Added"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
}

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @AppStorage("autoDownloadEnabled") private var autoDownloadEnabled = false
    @AppStorage("autoDownloadMode") private var autoDownloadMode = AutoDownloadMode.defaultMode.rawValue
    @State private var showDeleteAllConfirmation = false
    @State private var isStartingDownloads = false
    @State private var searchText = ""
    @State private var sortOrder = DownloadSortOrder.dateAdded
    @State private var displayTracks: [DownloadedTrackRecord] = []
    @State private var sortGeneration: Int = 0

    private var allTracks: [DownloadedTrackRecord] {
        downloadManager.downloadedTracksSorted
    }

    var body: some View {
        List {
            if !displayTracks.isEmpty {
                Section {
                    ForEach(displayTracks) { record in
                        trackRow(record)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            downloadManager.deleteDownload(ratingKey: displayTracks[index].ratingKey)
                        }
                    }
                } header: {
                    Text(storageText(tracks: allTracks))
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search Downloads")
        .navigationTitle("Downloads")
        .overlay {
            if allTracks.isEmpty {
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
            } else if displayTracks.isEmpty {
                ContentUnavailableView.search(text: searchText)
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
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(DownloadSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .tint(.primary)
                if !allTracks.isEmpty {
                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.primary)
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
        // Re-run whenever search text or sort order changes.
        .task(id: "\(searchText)|\(sortOrder.rawValue)") {
            await applyDisplayState()
        }
        // Re-run when downloads are added or removed.
        .onChange(of: downloadManager.records.count) { _, _ in
            Task { await applyDisplayState() }
        }
    }

    private func applyDisplayState() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSort = sortOrder
        let snapshot = allTracks

        sortGeneration &+= 1
        let myGeneration = sortGeneration

        let result = await Task.detached(priority: .userInitiated) {
            Self.filterAndSort(snapshot, query: query, sortOrder: currentSort)
        }.value

        guard sortGeneration == myGeneration else { return }
        displayTracks = result
    }

    nonisolated private static func filterAndSort(
        _ tracks: [DownloadedTrackRecord],
        query: String,
        sortOrder: DownloadSortOrder
    ) -> [DownloadedTrackRecord] {
        let base = query.isEmpty ? tracks : tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artistName.localizedCaseInsensitiveContains(query) ||
            $0.albumName.localizedCaseInsensitiveContains(query)
        }
        return switch sortOrder {
        case .dateAdded: base
        case .title: base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: base.sorted { $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending }
        case .album: base.sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
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
    private func trackRow(_ record: DownloadedTrackRecord) -> some View {
        let isCurrentTrack = player.currentTrack?.ratingKey == record.ratingKey
        Button {
            let playQueue = displayTracks.map { $0.asPlexMetadata() }
            let startIndex = playQueue.firstIndex(where: { $0.ratingKey == record.ratingKey }) ?? 0
            player.play(tracks: playQueue, startingAt: startIndex)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(isCurrentTrack ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Text("\(record.artistName) — \(record.albumName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.down.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.tint.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                downloadManager.deleteDownload(ratingKey: record.ratingKey)
            } label: {
                Image(systemName: "trash")
            }
            .tint(.red)
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
