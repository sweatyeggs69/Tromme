import SwiftUI

struct AllSongsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    @State private var loadedTracks: [PlexMetadata] = []
    @State private var displayTracks: [PlexMetadata] = []
    @State private var displaySections: [(title: String, items: [(index: Int, track: PlexMetadata)])] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @AppStorage("allSongsSortOrder") private var sortOrder: SongSortOrder = .titleAscending
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
                                    artworkSize: 48,
                                    artworkCornerRadius: 4
                                )
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                        }
                        .sectionIndexLabel(section.title)
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(2)
                .listSectionIndexVisibility(isDateAddedSortActive ? .hidden : .automatic)
                .tint(.secondary)
            }
        }
        .navigationTitle("Songs")
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
        .task {
            if let preview = previewTracks {
                loadedTracks = preview
                isLoading = false
                await applyDisplayState()
            } else {
                await loadTracks()
            }
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

    private func loadTracks() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        do {
            loadedTracks = try await client.cachedTracks(server: server, sectionId: sectionId)
        } catch {}
        isLoading = false
        await applyDisplayState()
    }

    // Sorts, filters, and sections all off the main actor to keep UI responsive at 100k tracks.
    private func applyDisplayState() async {
        guard !loadedTracks.isEmpty else { return }
        let snapshot = loadedTracks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSort = sortOrder

        let (sorted, sections) = await Task.detached(priority: .userInitiated) {
            let base = query.isEmpty ? snapshot : snapshot.filter { track in
                track.title.localizedCaseInsensitiveContains(query)
                || (track.grandparentTitle?.localizedCaseInsensitiveContains(query) ?? false)
                || (track.parentTitle?.localizedCaseInsensitiveContains(query) ?? false)
            }
            let sorted = Self.sort(base, by: currentSort)
            return (sorted, Self.buildSections(from: sorted, sortOrder: currentSort))
        }.value

        displayTracks = sorted
        displaySections = sections
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
        guard let first = trimmed.first else { return "#" }
        let letter = String(first).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
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
