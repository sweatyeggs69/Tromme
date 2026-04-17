import SwiftUI

struct ArtistsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale

    @State private var artists: [PlexMetadata] = []
    @State private var isLoading = true
    @AppStorage("artistsViewMode") private var viewMode: ArtistsViewMode = .list

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
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
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .list:
            List(artists) { artist in
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

        case .grid:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            VStack(alignment: .leading, spacing: 4) {
                                ArtworkView(thumbPath: artist.thumb, size: 184, cornerRadius: 92)

                                Text(artist.title)
                                    .appItemTitleStyle()
                            }
                            .frame(width: 184, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private var artworkPrefetchKey: String {
        "\(viewMode.rawValue)|\(artists.count)"
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
        let urls = artists.prefix(prefetchCount).compactMap { artist in
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
