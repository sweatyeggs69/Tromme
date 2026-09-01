import SwiftUI

struct AllSongsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player
    @Environment(NetworkStatus.self) private var network
    @Environment(DownloadManager.self) private var downloadManager

    @State private var loadedTracks: [PlexMetadata] = []
    @State private var displayTracks: [PlexMetadata] = []
    @State private var displaySections: [(title: String, items: [(index: Int, track: PlexMetadata)])] = []
    @State private var sortGeneration: Int = 0
    @State private var lastSortedCount: Int = -1
    @State private var lastSortedOrder: SongSortOrder = .titleAscending
    @State private var lastSortedQuery: String = ""
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @AppStorage("allSongsSortOrder") private var sortOrder: SongSortOrder = .titleAscending
    @AppStorage("autoDownloadEnabled") private var autoDownloadEnabled = false
    @AppStorage("autoDownloadMode") private var autoDownloadMode = AutoDownloadMode.defaultMode.rawValue
    @State private var trackNavigationTarget: PlexMetadata? = nil
    private let previewTracks: [PlexMetadata]?

    init(previewTracks: [PlexMetadata]? = nil) {
        self.previewTracks = previewTracks
        _isLoading = State(initialValue: previewTracks == nil)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displaySections.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if displaySections.isEmpty && !network.isConnected {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("You're offline. Download songs to listen without a connection.")
                }
            } else {
                List {
                    ForEach(displaySections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.items, id: \.track.id) { item in
                                TrackRowView(
                                    track: item.track,
                                    tracks: displayTracks,
                                    index: item.index,
                                    showArtwork: true,
                                    showArtist: true,
                                    showTrackNumber: false,
                                    artworkSize: AppStyle.TrackList.browseArtworkSize,
                                    artworkCornerRadius: AppStyle.TrackList.artworkCornerRadius,
                                    onNavigate: { trackNavigationTarget = $0 }
                                )
                                .listRowInsets(AppStyle.TrackList.rowInsets)
                            }
                        }
                        .sectionIndexLabel(section.title)
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(AppStyle.TrackList.rowSpacing)
                .listSectionIndexVisibility(isDateAddedSortActive ? .hidden : .automatic)
                .tint(.secondary)
            }
        }
        .navigationTitle("Songs")
        .navigationDestination(item: $trackNavigationTarget) { target in
            if target.type == "artist" {
                ArtistDetailView(artist: target)
            } else {
                AlbumDetailView(album: target)
            }
        }
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Filter songs"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        sortOrder = sortOrder == .titleAscending ? .titleDescending : .titleAscending
                    } label: {
                        if isTitleSortActive {
                            Label("Title", systemImage: "checkmark")
                            Text(sortOrder == .titleDescending ? "Z to A" : "A to Z")
                        } else {
                            Text("Title")
                        }
                    }

                    Button {
                        sortOrder = sortOrder == .artistAscending ? .artistDescending : .artistAscending
                    } label: {
                        if isArtistSortActive {
                            Label("Artist", systemImage: "checkmark")
                            Text(sortOrder == .artistDescending ? "Z to A" : "A to Z")
                        } else {
                            Text("Artist")
                        }
                    }

                    Button {
                        sortOrder = sortOrder == .dateAddedNewest ? .dateAddedOldest : .dateAddedNewest
                    } label: {
                        if isDateAddedSortActive {
                            Label("Date Added", systemImage: "checkmark")
                            Text(sortOrder == .dateAddedOldest ? "Oldest First" : "Newest First")
                        } else {
                            Text("Date Added")
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .tint(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    var shuffled = displayTracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled)
                } label: {
                    Image(systemName: "shuffle")
                }
                .tint(.primary)
                .disabled(displayTracks.isEmpty)
            }
        }
        .task(id: previewTracks != nil ? "preview" : "\(network.isConnected)") {
            if let preview = previewTracks {
                loadedTracks = preview
                isLoading = false
                await applyDisplayState()
            } else {
                await loadTracksForCurrentState()
            }
        }
        .onChange(of: downloadManager.records.count) { _, _ in
            guard previewTracks == nil, !network.isConnected else { return }
            Task { await loadTracksForCurrentState() }
        }
        // Cancels and restarts whenever sort order or search text changes.
        .task(id: "\(sortOrder.rawValue)|\(searchText)") {
            await applyDisplayState()
        }
        .onDisappear {
            searchText = ""
            isSearchPresented = false
        }
    }

    private var isTitleSortActive: Bool {
        sortOrder == .titleAscending || sortOrder == .titleDescending
    }

    private var isArtistSortActive: Bool {
        sortOrder == .artistAscending || sortOrder == .artistDescending
    }

    private var isDateAddedSortActive: Bool {
        sortOrder == .dateAddedNewest || sortOrder == .dateAddedOldest
    }

    private func loadTracksForCurrentState() async {
        if network.isConnected {
            await loadTracks()
        } else {
            loadedTracks = downloadManager.downloadedTracksSorted.map { $0.asPlexMetadata() }
            isLoading = false
            await applyDisplayState()
        }
    }

    private func loadTracks() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }

        // Pre-populate from memory cache synchronously (no actor hop needed).
        // Eliminates the spinner flash when the memory cache is warm.
        let cacheKey = CacheKey.tracks(serverId: server.machineIdentifier, sectionId: sectionId)
        if let cached = LibraryCache.shared.memoryCached([PlexMetadata].self, forKey: cacheKey), !cached.isEmpty {
            loadedTracks = cached
            isLoading = false
            await applyDisplayState()
        }

        do {
            loadedTracks = try await client.cachedTracks(server: server, sectionId: sectionId)
            if autoDownloadEnabled,
               autoDownloadMode == AutoDownloadMode.library.rawValue,
               !downloadManager.userStoppedAutoDownload {
                downloadManager.downloadBatch(tracks: loadedTracks, server: server, client: client)
            }
        } catch {
#if DEBUG
            print("[AllSongsView] Failed to load tracks: \(error)")
#endif
        }
        isLoading = false
        await applyDisplayState()
    }

    // Sorts, filters, and sections all off the main actor to keep UI responsive at 100k tracks.
    // Skips work if the data and sort parameters haven't changed since the last sort.
    // A generation counter ensures only the most recent sort request writes to state,
    // preventing stale results from piled-up tasks when navigating between tabs quickly.
    private func applyDisplayState() async {
        guard !loadedTracks.isEmpty else {
            displayTracks = []
            displaySections = []
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSort = sortOrder

        // Nothing changed since the last sort — skip the work entirely.
        if !displaySections.isEmpty,
           loadedTracks.count == lastSortedCount,
           currentSort == lastSortedOrder,
           query == lastSortedQuery {
            return
        }

        let snapshot = loadedTracks
        sortGeneration &+= 1
        let myGeneration = sortGeneration

        let (sorted, sections) = await Task.detached(priority: .userInitiated) {
            let base = query.isEmpty ? snapshot : snapshot.filter { track in
                track.title.localizedCaseInsensitiveContains(query)
                || (track.grandparentTitle?.localizedCaseInsensitiveContains(query) ?? false)
                || (track.parentTitle?.localizedCaseInsensitiveContains(query) ?? false)
            }
            let sorted = Self.sort(base, by: currentSort)
            return (sorted, Self.buildSections(from: sorted, sortOrder: currentSort))
        }.value

        guard sortGeneration == myGeneration else { return }
        displayTracks = sorted
        displaySections = sections
        lastSortedCount = loadedTracks.count
        lastSortedOrder = currentSort
        lastSortedQuery = query
    }

    nonisolated private static func sort(_ tracks: [PlexMetadata], by order: SongSortOrder) -> [PlexMetadata] {
        switch order {
        case .titleAscending:
            return tracks.sorted {
                ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedAscending
            }
        case .titleDescending:
            return tracks.sorted {
                ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedDescending
            }
        case .artistAscending:
            return tracks.sorted {
                let a0 = $0.grandparentTitle ?? "", a1 = $1.grandparentTitle ?? ""
                if a0 != a1 { return a0.localizedStandardCompare(a1) == .orderedAscending }
                return ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedAscending
            }
        case .artistDescending:
            return tracks.sorted {
                let a0 = $0.grandparentTitle ?? "", a1 = $1.grandparentTitle ?? ""
                if a0 != a1 { return a0.localizedStandardCompare(a1) == .orderedDescending }
                return ($0.titleSort ?? $0.title).localizedStandardCompare($1.titleSort ?? $1.title) == .orderedAscending
            }
        case .dateAddedNewest:
            return tracks.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        case .dateAddedOldest:
            return tracks.sorted { ($0.addedAt ?? 0) < ($1.addedAt ?? 0) }
        }
    }

    nonisolated private static func buildSections(
        from tracks: [PlexMetadata],
        sortOrder: SongSortOrder
    ) -> [(title: String, items: [(index: Int, track: PlexMetadata)])] {
        var sectionItems: [String: [(index: Int, track: PlexMetadata)]] = [:]
        var sectionOrder: [String] = []
        for (offset, track) in tracks.enumerated() {
            let title: String
            switch sortOrder {
            case .titleAscending, .titleDescending:
                title = alphabetSectionTitle(for: track.titleSort ?? track.title)
            case .artistAscending, .artistDescending:
                title = alphabetSectionTitle(for: track.grandparentTitle ?? "")
            case .dateAddedNewest, .dateAddedOldest:
                if let ts = track.addedAt {
                    let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(ts)))
                    title = String(year)
                } else {
                    title = "#"
                }
            }
            if sectionItems[title] == nil { sectionOrder.append(title) }
            sectionItems[title, default: []].append((index: offset, track: track))
        }
        return sectionOrder.map { ($0, sectionItems[$0]!) }
    }

    nonisolated private static func alphabetSectionTitle(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first.isASCII, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}

private enum SongSortOrder: String {
    case titleAscending
    case titleDescending
    case artistAscending
    case artistDescending
    case dateAddedNewest
    case dateAddedOldest
}

#if DEBUG
#Preview {
    NavigationStack {
        AllSongsView(previewTracks: DevelopmentMockData.allSongs)
    }
    .environment(AudioPlayerService())
}
#endif
