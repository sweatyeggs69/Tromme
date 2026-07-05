import SwiftUI

struct AllSongsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    // Stable sorted list of all tracks — never mutated after initial load.
    @State private var tracks: [PlexMetadata] = []
    // Pre-built sections for the full list — rebuilt once after load.
    @State private var allSections: [(title: String, items: [(index: Int, track: PlexMetadata)])] = []
    // Current display state — either allSections or a filtered subset.
    @State private var displayTracks: [PlexMetadata] = []
    @State private var displaySections: [(title: String, items: [(index: Int, track: PlexMetadata)])] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var isSearchPresented = false
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
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(2)
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
                let (sorted, sections) = await Self.sortAndBuildSections(preview)
                tracks = sorted
                allSections = sections
                displayTracks = sorted
                displaySections = sections
                isLoading = false
            } else {
                await loadTracks()
            }
        }
        // Cancels and restarts whenever searchText changes; keeps search responsive.
        .task(id: searchText) {
            await applySearch()
        }
        .onDisappear {
            searchText = ""
            isSearchPresented = false
        }
    }

    private func loadTracks() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        do {
            let fetched = try await client.cachedTracks(server: server, sectionId: sectionId)
            // Sort and index off the main actor — avoids blocking UI on large libraries.
            let (sorted, sections) = await Self.sortAndBuildSections(fetched)
            tracks = sorted
            allSections = sections
            displayTracks = sorted
            displaySections = sections
        } catch {}
        isLoading = false
    }

    private func applySearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            displayTracks = tracks
            displaySections = allSections
            return
        }
        let snapshot = tracks
        // Filter off the main actor so keystrokes stay responsive at 100k tracks.
        let filtered = await Task.detached(priority: .userInitiated) {
            snapshot.filter { track in
                track.title.localizedCaseInsensitiveContains(query)
                || (track.grandparentTitle?.localizedCaseInsensitiveContains(query) ?? false)
                || (track.parentTitle?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }.value
        displayTracks = filtered
        displaySections = Self.buildSections(from: filtered)
    }

    // Offloads the sort (O(n log n)) and section indexing (O(n)) off the main actor.
    nonisolated private static func sortAndBuildSections(_ unsorted: [PlexMetadata]) async -> ([PlexMetadata], [(title: String, items: [(index: Int, track: PlexMetadata)])]) {
        await Task.detached(priority: .userInitiated) {
            let sorted = unsorted.sorted { ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title) }
            return (sorted, Self.buildSections(from: sorted))
        }.value
    }

    nonisolated private static func buildSections(from tracks: [PlexMetadata]) -> [(title: String, items: [(index: Int, track: PlexMetadata)])] {
        var sectionItems: [String: [(index: Int, track: PlexMetadata)]] = [:]
        var sectionOrder: [String] = []
        for (offset, track) in tracks.enumerated() {
            let title = alphabetSectionTitle(for: track.titleSort ?? track.title)
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

#if DEBUG
#Preview {
    NavigationStack {
        AllSongsView(previewTracks: DevelopmentMockData.allSongs)
    }
    .environment(AudioPlayerService())
}
#endif
