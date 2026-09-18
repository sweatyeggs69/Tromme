import SwiftUI

struct PlaylistsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var playlists: [PlexPlaylist] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var isSearchPresented = false

    private var filteredPlaylists: [PlexPlaylist] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return playlists }
        let normalizedQuery = Self.normalizeForSearch(query)
        return playlists.filter { Self.normalizeForSearch($0.title).contains(normalizedQuery) }
    }

    private var exactMatches: [PlexPlaylist] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return filteredPlaylists.filter { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Lowercases and strips punctuation so general results ignore punctuation (e.g. "back then" matches "BACK, THEN").
    private static func normalizeForSearch(_ string: String) -> String {
        let scalars = string.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
            .split(separator: " ")
            .joined(separator: " ")
    }

    private var playlistSections: [(title: String, items: [PlexPlaylist])] {
        var sectionItems: [String: [PlexPlaylist]] = [:]
        var sectionOrder: [String] = []
        for playlist in filteredPlaylists {
            let title = alphabetSectionTitle(for: playlist.title)
            if sectionItems[title] == nil { sectionOrder.append(title) }
            sectionItems[title, default: []].append(playlist)
        }
        var sections = sectionOrder.map { ($0, sectionItems[$0]!) }
        if !exactMatches.isEmpty {
            sections.insert((title: "Exact Matches", items: exactMatches), at: 0)
        }
        return sections
    }

    private func alphabetSectionTitle(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let letter = String(first).uppercased()
        return letter.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : letter
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Create playlists in Plex to see them here.")
                )
            } else if filteredPlaylists.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(playlistSections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.items) { playlist in
                                NavigationLink {
                                    PlaylistDetailView(playlist: playlist)
                                } label: {
                                    HStack(spacing: 12) {
                                        ArtworkView(thumbPath: playlist.thumb ?? playlist.composite, size: 48, cornerRadius: 4)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(playlist.title)
                                                .appItemTitleStyle()
                                                .lineLimit(1)

                                            if let count = playlist.leafCount {
                                                Text("\(count) songs")
                                                    .appItemSubtitleStyle()
                                            }
                                        }
                                    }
                                }
                                .listRowInsets(AppStyle.TrackList.rowInsets)
                            }
                        }
                        .sectionIndexLabel(section.title == "Exact Matches" ? nil : section.title)
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(AppStyle.TrackList.rowSpacing)
                .listSectionIndexVisibility(.automatic)
                .tint(.secondary)
            }
        }
        .navigationTitle("Playlists")
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search playlists"
        )
        .task { await loadPlaylists() }
        .refreshable { await loadPlaylists() }
        .onDisappear {
            searchText = ""
            isSearchPresented = false
        }
    }

    private func loadPlaylists() async {
        guard let server = serverConnection.currentServer else {
            playlists = []
            isLoading = false
            return
        }

        // Pre-populate from memory cache synchronously (no actor hop needed).
        // Eliminates the spinner flash when the memory cache is warm.
        let cacheKey = CacheKey.playlists(serverId: server.machineIdentifier)
        if let cached = LibraryCache.shared.memoryCached([PlexPlaylist].self, forKey: cacheKey), !cached.isEmpty {
            playlists = cached.filter(\.isMusicPlaylist)
            isLoading = false
        }

        do {
            let all = try await client.cachedPlaylists(server: server)
            playlists = all.filter(\.isMusicPlaylist)
        } catch {
            if playlists.isEmpty { playlists = [] }
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        PlaylistsView()
    }
}
