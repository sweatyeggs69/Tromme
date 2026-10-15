import SwiftUI

struct HomeView: View {
    @Environment(\.plexClient) private var client
    @Environment(\.serverConnection) private var serverConnection
    @Environment(\.displayScale) private var displayScale
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.appAccentColor) private var appAccentColor

    @State private var viewModel: HomeViewModel
    @State private var addToPlaylistRequest: AddToPlaylistRequest?
    @State private var showingLibrarySwitcher = false
    @State private var showingSignOutConfirmation = false

    @AppStorage("showFeaturedSection") private var showFeaturedSection = true
    @AppStorage("hideEmptySections") private var hideEmptySections = false

    private let onSignOut: () -> Void

    // Read-only views of the view model's state, so the body reads as before.
    private var favoriteTracks: [PlexMetadata] { viewModel.favoriteTracks }
    private var recentTracks: [PlexMetadata] { viewModel.recentTracks }
    private var playlists: [PlexPlaylist] { viewModel.playlists }
    private var recentAlbums: [PlexMetadata] { viewModel.recentAlbums }
    private var featuredAlbums: [PlexMetadata] { viewModel.featuredAlbums }
    private var isLoading: Bool { viewModel.isLoading }

    private var loadContext: HomeViewModel.Context {
        HomeViewModel.Context(
            server: serverConnection.currentServer,
            sectionId: serverConnection.currentLibrarySectionId,
            client: client,
            displayScale: displayScale
        )
    }

    init(
        previewRecentTracks: [PlexMetadata]? = nil,
        previewPlaylists: [PlexPlaylist]? = nil,
        previewRecentAlbums: [PlexMetadata]? = nil,
        onSignOut: @escaping () -> Void = {}
    ) {
        self.onSignOut = onSignOut
        _viewModel = State(initialValue: HomeViewModel(
            previewRecentTracks: previewRecentTracks,
            previewPlaylists: previewPlaylists,
            previewRecentAlbums: previewRecentAlbums
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showFeaturedSection {
                    featuredSection
                }
                if !hideEmptySections || isLoading || !favoriteTracks.isEmpty {
                    favoritesSection
                }
                recentlyAddedSection
                recentlyPlayedSection
                if !hideEmptySections || isLoading || !playlists.isEmpty {
                    playlistsSection
                }
            }
            .padding(.bottom, 8)
            .padding(.top, 8)
        }
        .refreshable {
            await viewModel.refresh(loadContext)
        }
        .task(id: loadTaskID) {
            await viewModel.load(loadContext)
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .favoritesDidChange) {
                guard !Task.isCancelled else { break }
                await viewModel.favoritesDidChange(loadContext)
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .libraryContentDidChange) {
                guard !Task.isCancelled else { break }
                await viewModel.libraryContentDidChange(loadContext)
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .recentlyPlayedDidChange) {
                guard !Task.isCancelled else { break }
                await viewModel.recentlyPlayedDidChange(loadContext)
            }
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Menu {
                    Button("Change Library", systemImage: "books.vertical") {
                        showingLibrarySwitcher = true
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        showingSignOutConfirmation = true
                    }
                } label: {
                    Text(serverConnection.currentServer?.name ?? "Home")
                        .font(.headline)
                }
                .tint(.primary)
            }
        }
        .sheet(item: $addToPlaylistRequest) { request in
            AddToPlaylistSheet(itemRatingKeys: request.itemRatingKeys)
        }
        .sheet(isPresented: $showingLibrarySwitcher) {
            LibrarySwitcherSheet()
        }
        .alert("Sign Out", isPresented: $showingSignOutConfirmation) {
            Button("Sign Out", role: .destructive) { onSignOut() }
            Button("Cancel", role: .cancel) {}
                .tint(.primary)
        } message: {
            Text("You'll need to sign in again to access your music.")
        }
    }

    private var loadTaskID: String {
        let sectionID = serverConnection.currentLibrarySectionId ?? "none"
        let serverURI = serverConnection.currentServer?.uri ?? "none"
        return "\(sectionID)|\(serverURI)"
    }

    @ViewBuilder
    private var featuredSection: some View {
        if !featuredAlbums.isEmpty {
            FeaturedCarouselView(albums: featuredAlbums)
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Group {
                if !favoriteTracks.isEmpty {
                    NavigationLink {
                        FavoritesView()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Favorites")
                                .font(AppStyle.Typography.sectionTitle)
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .imageScale(.small)
                        }
                        .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                } else {
                    Text("Favorites")
                        .font(AppStyle.Typography.sectionTitle)
                }
            }
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if favoriteTracks.isEmpty {
                ContentUnavailableView(
                    "No Favorites",
                    systemImage: "heart",
                    description: Text("Favorite songs in Plex to see them here.")
                )
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            } else {
                tracksHorizontalRow(tracks: favoriteTracks, showFavoriteStar: false)
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
                albumCardsRow(recentAlbums)
            }
        }
    }
    
    private func albumCardsRow(_ albums: [PlexMetadata]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 4) {
                            ArtworkView(
                                thumbPath: album.thumb,
                                size: AppStyle.Artwork.card,
                                cornerRadius: AppStyle.Radius.card
                            )

                            Text(album.title)
                                .appItemTitleStyle()

                            Text(album.parentTitle ?? "")
                                .appItemSubtitleStyle()
                        }
                        .frame(width: AppStyle.Artwork.card, alignment: .topLeading)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        albumContextMenu(for: album)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
        }
        .scrollTargetBehavior(.viewAligned)
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
                if recentTracks.allSatisfy({ $0.type == "track" }) {
                    tracksHorizontalRow(tracks: recentTracks)
                } else {
                    albumCardsRow(recentTracks)
                }
            }
        }
    }

    private func tracksHorizontalRow(tracks: [PlexMetadata], showFavoriteStar: Bool = true) -> some View {
        HorizontalTrackGrid(tracks: tracks, showFavoriteStar: showFavoriteStar)
    }

    @ViewBuilder
    private func albumContextMenu(for album: PlexMetadata) -> some View {
        Group {
            Button("Play Next", systemImage: "text.insert") {
                Task { await queueAlbumNext(album) }
            }
            Button("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                Task { await queueAlbumLast(album) }
            }
            Button("Add to Playlist", systemImage: "text.badge.plus") {
                Task { await presentAddAlbumToPlaylist(album) }
            }
        }
        .tint(appAccentColor)
    }

    @MainActor
    private func queueAlbumNext(_ album: PlexMetadata) async {
        guard let tracks = await viewModel.tracks(of: album, loadContext) else { return }
        for track in tracks.reversed() {
            player.addToQueue(track)
        }
    }

    @MainActor
    private func queueAlbumLast(_ album: PlexMetadata) async {
        guard let tracks = await viewModel.tracks(of: album, loadContext) else { return }
        for track in tracks {
            player.addToEndOfQueue(track)
        }
    }

    @MainActor
    private func presentAddAlbumToPlaylist(_ album: PlexMetadata) async {
        guard let tracks = await viewModel.tracks(of: album, loadContext) else { return }
        addToPlaylistRequest = AddToPlaylistRequest(itemRatingKeys: tracks.map(\.ratingKey))
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.sectionGap) {
            Group {
                if !playlists.isEmpty {
                    NavigationLink {
                        PlaylistsView()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Playlists")
                                .font(AppStyle.Typography.sectionTitle)
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .imageScale(.small)
                        }
                        .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                } else {
                    Text("Playlists")
                        .font(AppStyle.Typography.sectionTitle)
                }
            }
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Create playlists in Plex to see them here.")
                )
                .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: playlist) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(
                                        thumbPath: playlist.thumb ?? playlist.composite,
                                        size: AppStyle.Artwork.card,
                                        cornerRadius: AppStyle.Radius.card
                                    )

                                    Text(playlist.title)
                                        .appItemTitleStyle()

                                    if let count = playlist.leafCount {
                                        Text("\(count) songs")
                                            .appItemSubtitleStyle()
                                    } else {
                                        Text("")
                                            .appItemSubtitleStyle()
                                    }
                                }
                                .frame(width: AppStyle.Artwork.card, alignment: .topLeading)
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
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeView(
            previewRecentTracks: DevelopmentMockData.recentTracks,
            previewPlaylists: [DevelopmentMockData.previewPlaylist],
            previewRecentAlbums: DevelopmentMockData.recentAlbums
        )
    }
    .environment(AudioPlayerService())
}
#endif
