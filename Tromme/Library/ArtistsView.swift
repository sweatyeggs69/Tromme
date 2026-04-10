import SwiftUI

struct ArtistsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var artists: [PlexMetadata] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @AppStorage("artistsViewMode") private var viewMode: ArtistsViewMode = .list

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

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
                .accessibilityLabel(viewMode == .grid ? "Show as list" : "Show as grid")
            }
        }
        .searchable(text: $searchText, prompt: "Find in Artists")
        .task { await loadArtists() }
        .refreshable { await loadArtists() }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .list:
            List(filteredArtists) { artist in
                NavigationLink(value: artist) {
                    HStack(spacing: 14) {
                        ArtworkView(thumbPath: artist.thumb, size: 48, cornerRadius: 24)

                        Text(artist.title)
                            .font(.body)
                    }
                }
            }
            .listStyle(.plain)

        case .grid:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(filteredArtists) { artist in
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

    private var filteredArtists: [PlexMetadata] {
        if searchText.isEmpty { return artists }
        return artists.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private func loadArtists() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        do {
            artists = try await client.cachedArtists(server: server, sectionId: sectionId)
            artists.sort { ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title) }
        } catch {
            // Handle error
        }
        isLoading = false
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
