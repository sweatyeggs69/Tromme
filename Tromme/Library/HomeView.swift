import SwiftUI

struct HomeView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection

    @State private var recentTracks: [PlexMetadata]
    @State private var recentAlbums: [PlexMetadata]
    @State private var isLoading: Bool

    private let previewRecentTracks: [PlexMetadata]?
    private let previewRecentAlbums: [PlexMetadata]?

    init(
        previewRecentTracks: [PlexMetadata]? = nil,
        previewRecentAlbums: [PlexMetadata]? = nil
    ) {
        self.previewRecentTracks = previewRecentTracks
        self.previewRecentAlbums = previewRecentAlbums
        _recentTracks = State(initialValue: previewRecentTracks ?? [])
        _recentAlbums = State(initialValue: previewRecentAlbums ?? [])
        _isLoading = State(initialValue: previewRecentTracks == nil && previewRecentAlbums == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                recentlyPlayedSection
                recentlyAddedSection
            }
            .padding(.vertical, 8)
        }
        .task {
            guard previewRecentTracks == nil && previewRecentAlbums == nil else { return }
            await loadHomeContent()
        }
        .refreshable {
            guard previewRecentTracks == nil && previewRecentAlbums == nil else { return }
            await loadHomeContent()
        }
    }

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Text("Recently Played")
                .appSectionTitleStyle()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if recentTracks.isEmpty {
                ContentUnavailableView(
                    "No Recently Played",
                    systemImage: "music.note.list",
                    description: Text("Play tracks to see them here.")
                )
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [
                            GridItem(.fixed(46), spacing: 10),
                            GridItem(.fixed(46), spacing: 10)
                        ],
                        spacing: AppStyle.Spacing.listItemGap
                    ) {
                        ForEach(Array(recentTracks.enumerated()), id: \.element.id) { index, track in
                            TrackRowView(
                                track: track,
                                tracks: recentTracks,
                                index: index,
                                showArtwork: true,
                                showArtist: true,
                                showTrackNumber: false,
                                artworkSize: 46,
                                showsMenu: false,
                                isCompact: true,
                                titleFont: AppStyle.Typography.itemTitle,
                                artistFont: AppStyle.Typography.itemSubtitle
                            )
                            .frame(width: 300, alignment: .leading)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Text("Recently Added")
                .appSectionTitleStyle()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if recentAlbums.isEmpty {
                ContentUnavailableView(
                    "No Recently Added",
                    systemImage: "square.stack",
                    description: Text("New albums and singles will appear here.")
                )
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [
                            GridItem(.fixed(220), spacing: 20)
                        ],
                        spacing: 12
                    ) {
                        ForEach(recentAlbums) { album in
                            NavigationLink(value: album) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(
                                        thumbPath: album.thumb,
                                        size: 150,
                                        cornerRadius: AppStyle.Radius.card
                                    )

                                    Text(album.title)
                                        .appItemTitleStyle()

                                    Text(album.parentTitle ?? "")
                                        .appItemSubtitleStyle()
                                }
                                .frame(width: 150, height: 220, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private func loadHomeContent() async {
        guard let server = serverConnection.currentServer,
              let sectionId = serverConnection.currentLibrarySectionId else {
            recentTracks = []
            recentAlbums = []
            isLoading = false
            return
        }

        do {
            async let tracksReq = client.cachedTracks(server: server, sectionId: sectionId)
            async let albumsReq = client.cachedAlbums(server: server, sectionId: sectionId)

            let allTracks = try await tracksReq
            let allAlbums = try await albumsReq

            recentTracks = Array(
                allTracks
                    .filter { ($0.lastViewedAt ?? 0) > 0 }
                    .sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
                    .prefix(10)
            )

            recentAlbums = Array(
                allAlbums
                    .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
                    .prefix(10)
            )
        } catch {
            recentTracks = []
            recentAlbums = []
        }

        isLoading = false
    }
}

#Preview {
    NavigationStack {
        HomeView(
            previewRecentTracks: DevelopmentMockData.recentTracks,
            previewRecentAlbums: DevelopmentMockData.recentAlbums
        )
    }
    .environment(AudioPlayerService())
}
