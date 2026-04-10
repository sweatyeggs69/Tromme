import SwiftUI

struct AllAlbumsView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var albums: [PlexMetadata]
    @State private var isLoading: Bool
    @State private var searchText = ""
    @AppStorage("allAlbumsViewMode") private var viewMode: AlbumViewMode = .grid

    private let previewAlbums: [PlexMetadata]?

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    init(previewAlbums: [PlexMetadata]? = nil) {
        self.previewAlbums = previewAlbums
        _albums = State(initialValue: previewAlbums ?? [])
        _isLoading = State(initialValue: previewAlbums == nil)
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
        .navigationTitle("Albums")
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
        .searchable(text: $searchText, prompt: "Find in Albums")
        .task {
            guard previewAlbums == nil else { return }
            await loadAlbums()
        }
        .refreshable {
            guard previewAlbums == nil else { return }
            await loadAlbums()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .grid:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 4) {
                                ArtworkView(thumbPath: album.thumb, size: 184, cornerRadius: 8)

                                Text(album.title)
                                    .appItemTitleStyle()

                                Text(album.parentTitle ?? "")
                                    .appItemSubtitleStyle()
                            }
                            .frame(width: 184, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

        case .list:
            List(filteredAlbums) { album in
                NavigationLink(value: album) {
                    HStack(spacing: 12) {
                        ArtworkView(thumbPath: album.thumb, size: 64, cornerRadius: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                                .appItemTitleStyle()

                            Text(album.parentTitle ?? "")
                                .appItemSubtitleStyle()
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private var filteredAlbums: [PlexMetadata] {
        if searchText.isEmpty { return albums }
        return albums.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.parentTitle ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private func loadAlbums() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else { return }
        do {
            albums = try await client.cachedAlbums(server: server, sectionId: sectionId)
            albums.sort { ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title) }
        } catch {
            // Handle error
        }
        isLoading = false
    }
}

private enum AlbumViewMode: String {
    case grid
    case list
}

#Preview {
    NavigationStack {
        AllAlbumsView(previewAlbums: DevelopmentMockData.allAlbums)
    }
}
