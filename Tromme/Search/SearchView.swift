import SwiftUI

struct SearchView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @Environment(AudioPlayerService.self) private var player

    @State private var searchText = ""
    @State private var hubs: [Hub] = []
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("recent_search_queries") private var recentSearchesStorage = "[]"

    private let maxRecentSearches = 12

    private var recentSearches: [String] {
        get {
            guard let data = recentSearchesStorage.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return decoded
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let stringValue = String(data: data, encoding: .utf8) else {
                return
            }
            recentSearchesStorage = stringValue
        }
    }

    var body: some View {
        Group {
            if searchText.isEmpty && hubs.isEmpty {
                if recentSearches.isEmpty {
                    ContentUnavailableView(
                        "Search Music",
                        systemImage: "magnifyingglass",
                        description: Text("Search for artists, albums, and songs.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(recentSearches, id: \.self) { query in
                                Button {
                                    searchText = query
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "clock")
                                            .foregroundStyle(.secondary)
                                        Text(query)
                                        Spacer()
                                        Image(systemName: "arrow.up.left")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete(perform: deleteRecentSearches)
                        } header: {
                            HStack {
                                Text("Recent Searches")
                                Spacer()
                                Button("Clear") {
                                    clearRecentSearches()
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            } else if hubs.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(hubs) { hub in
                        if let items = hub.metadata, !items.isEmpty {
                            Section(hub.title ?? "Results") {
                                ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { index, item in
                                    searchResultRow(item: item, allItems: items, index: index)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Artists, Songs, Albums & More")
        .onSubmit(of: .search) {
            rememberSearch(searchText)
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await performSearch(query: newValue)
            }
        }
    }

    private func rememberSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(trimmed, at: 0)
        if updated.count > maxRecentSearches {
            updated = Array(updated.prefix(maxRecentSearches))
        }
        recentSearches = updated
    }

    private func clearRecentSearches() {
        recentSearches = []
    }

    private func deleteRecentSearches(at offsets: IndexSet) {
        var updated = recentSearches
        updated.remove(atOffsets: offsets)
        recentSearches = updated
    }

    @ViewBuilder
    private func searchResultRow(item: PlexMetadata, allItems: [PlexMetadata], index: Int) -> some View {
        switch item.type {
        case "artist":
            NavigationLink(value: item) {
                HStack(spacing: 12) {
                    ArtworkView(thumbPath: item.thumb, size: 44, cornerRadius: 22)
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text("Artist").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case "album":
            NavigationLink(value: item) {
                HStack(spacing: 12) {
                    ArtworkView(thumbPath: item.thumb, size: 44, cornerRadius: 8)
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text(item.parentTitle ?? "Album").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        default:
            let trackItems = allItems.filter { $0.type == "track" }
            let trackIndex = trackItems.firstIndex(where: { $0.ratingKey == item.ratingKey }) ?? 0
            TrackRowView(
                track: item,
                tracks: trackItems,
                index: trackIndex,
                showArtwork: true,
                showArtist: true,
                showTrackNumber: false
            )
        }
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty else {
            hubs = []
            return
        }
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }

        let lowered = query.lowercased()

        let artists = (try? await client.cachedArtists(server: server, sectionId: sectionId)) ?? []
        let albums = (try? await client.cachedAlbums(server: server, sectionId: sectionId)) ?? []
        let tracks = (try? await client.cachedTracks(server: server, sectionId: sectionId)) ?? []

        var matchedArtists = artists.filter { $0.title.lowercased().contains(lowered) }

        // Include artists found via tracks that aren't in the artists list
        let matchedArtistNames = Set(matchedArtists.map { $0.title.lowercased() })
        let trackArtistKeys = Set(tracks.compactMap { track -> String? in
            guard let artistName = track.grandparentTitle,
                  artistName.lowercased().contains(lowered),
                  !matchedArtistNames.contains(artistName.lowercased()),
                  let key = track.grandparentRatingKey else { return nil }
            return key
        })
        for key in trackArtistKeys {
            if let track = tracks.first(where: { $0.grandparentRatingKey == key }),
               let artistName = track.grandparentTitle {
                matchedArtists.append(PlexMetadata(
                    ratingKey: key,
                    title: artistName,
                    type: "artist",
                    thumb: track.grandparentThumb
                ))
            }
        }
        let matchedAlbums = albums.filter { $0.title.lowercased().contains(lowered) || ($0.parentTitle?.lowercased().contains(lowered) ?? false) }
        let matchedTracks = tracks.filter {
            $0.title.lowercased().contains(lowered)
            || ($0.grandparentTitle?.lowercased().contains(lowered) ?? false)
            || ($0.parentTitle?.lowercased().contains(lowered) ?? false)
        }

        var results: [Hub] = []
        if !matchedArtists.isEmpty {
            results.append(Hub(hubIdentifier: "artists", title: "Artists", type: "artist", size: matchedArtists.count, metadata: Array(matchedArtists.prefix(5))))
        }
        if !matchedAlbums.isEmpty {
            results.append(Hub(hubIdentifier: "albums", title: "Albums", type: "album", size: matchedAlbums.count, metadata: Array(matchedAlbums.prefix(5))))
        }
        if !matchedTracks.isEmpty {
            results.append(Hub(hubIdentifier: "tracks", title: "Songs", type: "track", size: matchedTracks.count, metadata: Array(matchedTracks.prefix(10))))
        }
        hubs = results
        await prefetchArtwork(for: results, server: server)
    }

    private func prefetchArtwork(for hubs: [Hub], server: PlexServer) async {
        var seen = Set<String>()
        let pointSize: CGFloat = 44
        let pixelSize = ArtworkView.recommendedTranscodeSize(pointSize: pointSize, displayScale: displayScale)
        let urls = hubs
            .flatMap { $0.metadata ?? [] }
            .compactMap { $0.thumb ?? $0.parentThumb }
            .filter { seen.insert($0).inserted }
            .prefix(40)
            .compactMap { path in
                client.artworkURL(server: server, path: path, width: pixelSize, height: pixelSize)
            }
        await ImageCache.shared.prefetch(urls: urls, targetPixelSize: pixelSize, maxConcurrent: 4)
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
    .environment(AudioPlayerService())
}
