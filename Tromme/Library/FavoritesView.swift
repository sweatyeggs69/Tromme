import SwiftUI

struct FavoritesView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @Environment(AudioPlayerService.self) private var player

    @State private var tracks: [PlexMetadata] = []
    @State private var filteredTracks: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var trackNavigationTarget: PlexMetadata? = nil
    private let previewTracks: [PlexMetadata]?

    init(previewTracks: [PlexMetadata]? = nil) {
        self.previewTracks = previewTracks
        _tracks = State(initialValue: previewTracks ?? [])
        _filteredTracks = State(initialValue: previewTracks ?? [])
        _isLoading = State(initialValue: previewTracks == nil)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Favorites", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        loadError = nil
                        Task { await loadTracks() }
                    }
                }
            } else {
                if filteredTracks.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if tracks.isEmpty {
                    ContentUnavailableView(
                        "No Favorites",
                        systemImage: "heart",
                        description: Text("Favorite songs in Plex to see them here.")
                    )
                } else {
                    List {
                        if !exactMatches.isEmpty {
                            Section("Exact Matches") {
                                ForEach(exactMatches) { track in
                                    trackRow(track, index: filteredTracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                                }
                            }
                        }
                        ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, index: index)
                        }
                    }
                    .listStyle(.plain)
                    .listRowSpacing(AppStyle.TrackList.rowSpacing)
                }
            }
        }
        .navigationTitle("Favorites")
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
            prompt: "Search favorites"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    var shuffled = filteredTracks
                    shuffled.shuffle()
                    player.play(tracks: shuffled)
                } label: {
                    Image(systemName: "shuffle")
                }
                .tint(.primary)
                .disabled(filteredTracks.isEmpty)
            }
        }
        .task {
            guard previewTracks == nil else { return }
            await loadTracks()
        }
        .task {
            guard previewTracks == nil else { return }
            for await _ in NotificationCenter.default.notifications(named: .favoritesDidChange) {
                guard !Task.isCancelled else { break }
                await loadTracks()
            }
        }
        // Re-filter off the main actor whenever tracks or search text changes.
        .task(id: searchText) {
            await applyFilter()
        }
        .onChange(of: tracks) { _, _ in
            Task { await applyFilter() }
        }
        .task(id: artworkPrefetchKey) {
            await prefetchVisibleArtwork()
        }
        .onDisappear {
            searchText = ""
            isSearchPresented = false
        }
    }

    private var artworkPrefetchKey: String {
        "\(filteredTracks.count)|\(searchText)"
    }

    private var exactMatches: [PlexMetadata] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return filteredTracks.filter { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Lowercases and strips punctuation so general results ignore punctuation (e.g. "back then" matches "BACK, THEN").
    nonisolated private static func normalizeForSearch(_ string: String) -> String {
        let scalars = string.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
            .split(separator: " ")
            .joined(separator: " ")
    }

    @ViewBuilder
    private func trackRow(_ track: PlexMetadata, index: Int) -> some View {
        TrackRowView(
            track: track,
            tracks: filteredTracks,
            index: index,
            showArtwork: true,
            showArtist: true,
            showTrackNumber: false,
            artworkSize: AppStyle.TrackList.browseArtworkSize,
            artworkCornerRadius: AppStyle.TrackList.artworkCornerRadius,
            onNavigate: { trackNavigationTarget = $0 }
        )
        .listRowInsets(AppStyle.TrackList.rowInsets)
    }

    private func applyFilter() async {
        let snapshot = tracks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await Task.detached(priority: .userInitiated) {
            guard !query.isEmpty else { return snapshot }
            let normalizedQuery = Self.normalizeForSearch(query)
            return snapshot.filter { track in
                Self.normalizeForSearch(track.title).contains(normalizedQuery)
                || (track.grandparentTitle.map { Self.normalizeForSearch($0).contains(normalizedQuery) } ?? false)
                || (track.parentTitle.map { Self.normalizeForSearch($0).contains(normalizedQuery) } ?? false)
            }
        }.value
        filteredTracks = result
    }

    private func prefetchVisibleArtwork() async {
        guard !isLoading, let server = serverConnection.currentServer else { return }
        // Skip aggressive prefetching on metered networks or in Low Power Mode —
        // images will still load lazily as the user scrolls.
        guard !NetworkStatus.shared.isExpensive,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let pixelSize = ArtworkView.recommendedTranscodeSize(pointSize: AppStyle.TrackList.browseArtworkSize, displayScale: displayScale)
        let urls = filteredTracks.prefix(80).compactMap { track in
            client.artworkURL(server: server, path: track.thumb ?? track.parentThumb, width: pixelSize, height: pixelSize)
        }
        await ImageCache.shared.prefetch(urls: urls, targetPixelSize: pixelSize, maxConcurrent: 4)
    }

    private func sortedFavorites(_ favorites: [PlexMetadata]) -> [PlexMetadata] {
        favorites.sorted {
            if ($0.userRating ?? 0) == ($1.userRating ?? 0) {
                return ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title)
            }
            return ($0.userRating ?? 0) > ($1.userRating ?? 0)
        }
    }

    private func loadTracks() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }

        // Pre-populate from memory cache synchronously (no actor hop needed).
        // Eliminates the spinner flash when the memory cache is warm.
        let cacheKey = CacheKey.favoriteTracks(serverId: server.machineIdentifier, sectionId: sectionId)
        if let cached = LibraryCache.shared.memoryCached([PlexMetadata].self, forKey: cacheKey), !cached.isEmpty {
            tracks = sortedFavorites(cached)
            isLoading = false
        }

        do {
            let favorites = try await client.cachedFavoriteTracks(server: server, sectionId: sectionId)
            tracks = sortedFavorites(favorites)
        } catch {
#if DEBUG
            print("[FavoritesView] Failed to load favorites: \(error)")
#endif
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FavoritesView(previewTracks: DevelopmentMockData.recentTracks)
    }
    .environment(AudioPlayerService())
}
#endif
