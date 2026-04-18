import SwiftUI

struct ArtistsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale

    @State private var artists: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @AppStorage("artistsViewMode") private var viewMode: ArtistsViewMode = .list

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isRegularLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var gridColumnSpacing: CGFloat {
        isRegularLayout ? 16 : 8
    }

    private var gridRowSpacing: CGFloat {
        isRegularLayout ? 18 : 10
    }

    private var gridHorizontalPadding: CGFloat {
        isRegularLayout ? 24 : 16
    }

    private var columns: [GridItem] {
        let count = isRegularLayout ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: gridColumnSpacing), count: count)
    }

    private var filteredArtists: [PlexMetadata] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return artists }
        return artists.filter { artist in
            artist.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                contentView
            }
        }
        .navigationTitle("Artists")
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Filter artists"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewMode = viewMode == .grid ? .list : .grid
                } label: {
                    Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                }
                .tint(.primary)
                .accessibilityLabel(viewMode == .grid ? "Show as list" : "Show as grid")
            }
        }
        .task { await loadArtists() }
        .task(id: artworkPrefetchKey) { await prefetchVisibleArtwork() }
        .onDisappear {
            searchText = ""
            isSearchPresented = false
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .list:
            if filteredArtists.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredArtists) { artist in
                    NavigationLink(value: artist) {
                        HStack(spacing: 10) {
                            ArtworkView(thumbPath: artist.thumb, size: 48, cornerRadius: 24)

                            Text(artist.title)
                                .font(.body)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .listStyle(.plain)
            }

        case .grid:
            if filteredArtists.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                        ForEach(filteredArtists) { artist in
                            NavigationLink(value: artist) {
                                VStack(alignment: .center, spacing: 4) {
                                    GeometryReader { geo in
                                        let size = geo.size.width
                                        ArtworkView(thumbPath: artist.thumb, size: size, cornerRadius: size / 2)
                                    }
                                    .aspectRatio(1, contentMode: .fit)

                                    Text(artist.title)
                                        .appItemTitleStyle()
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, gridHorizontalPadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var artworkPrefetchKey: String {
        "\(viewMode.rawValue)|\(filteredArtists.count)|\(searchText)"
    }

    private func loadArtists() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        do {
            var result = try await client.cachedArtists(server: server, sectionId: sectionId)
            let knownKeys = Set(result.map(\.ratingKey))

            // Discover artists that only have singles/tracks but no artist entry
            let tracks = try await client.cachedTracks(server: server, sectionId: sectionId)
            var seen = Set<String>()
            for track in tracks {
                guard let key = track.grandparentRatingKey,
                      !knownKeys.contains(key),
                      seen.insert(key).inserted,
                      let name = track.grandparentTitle else { continue }
                result.append(PlexMetadata(
                    ratingKey: key,
                    title: name,
                    type: "artist",
                    thumb: track.grandparentThumb
                ))
            }

            result.sort {
                artistSortKey(for: $0.title) < artistSortKey(for: $1.title)
            }
            artists = result
        } catch {}
        isLoading = false
    }

    private func prefetchVisibleArtwork() async {
        guard !isLoading, let server = serverConnection.currentServer else { return }
        let prefetchCount = viewMode == .grid ? 60 : 80
        let pointSize: CGFloat = viewMode == .grid ? 184 : 48
        let pixelSize = ArtworkView.recommendedTranscodeSize(pointSize: pointSize, displayScale: displayScale)
        let urls = filteredArtists.prefix(prefetchCount).compactMap { artist in
            client.artworkURL(server: server, path: artist.thumb, width: pixelSize, height: pixelSize)
        }
        await ImageCache.shared.prefetch(urls: urls, targetPixelSize: pixelSize, maxConcurrent: 4)
    }

    private func artistSortKey(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let withoutThe: String
        if lower.hasPrefix("the ") {
            withoutThe = String(trimmed.dropFirst(4))
        } else if lower.hasSuffix(", the") {
            withoutThe = String(trimmed.dropLast(5))
        } else {
            withoutThe = trimmed
        }

        let normalized = withoutThe.trimmingCharacters(in: .whitespacesAndNewlines)

        let firstWord = normalized
            .split(whereSeparator: \.isWhitespace)
            .first.map(String.init) ?? normalized

        return "\(firstWord.lowercased())|\(normalized.lowercased())"
    }
}

private enum ArtistsViewMode: String {
    case list
    case grid
}

#Preview {
    NavigationStack {
        ArtistsView()
    }
}
