import SwiftUI

struct ContentView: View {
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    @Environment(\.plexClient) private var client

    @State private var authToken: String? = KeychainHelper.load(forKey: "plexAuthToken")
    @State private var showNowPlaying = false
    @State private var nowPlayingStartPanel: NowPlayingStartPanel = .none
    @State private var discoveryError: String?
    @State private var selectedTab: String = "home"
    @State private var artistsPath = NavigationPath()
    @State private var albumsPath = NavigationPath()
    @State private var pendingNavigation: PlexMetadata?

    var body: some View {
        Group {
            if authToken == nil {
                LoginView { token in
                    authToken = token
                }
            } else if serverConnection.currentServer == nil {
                if serverConnection.availableServers.count > 1 {
                    serverPickerView
                } else {
                    serverDiscoveryView
                }
            } else if serverConnection.currentLibrarySectionId == nil {
                LibraryPickerView {
                    // Library selected
                }
            } else {
                mainTabView
            }
        }
    }

    @ViewBuilder
    private var serverDiscoveryView: some View {
        if let error = discoveryError {
            ContentUnavailableView {
                Label("No Server Found", systemImage: "server.rack")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") {
                    discoveryError = nil
                    Task { await discover() }
                }
                Button("Sign Out") { signOut() }
            }
        } else {
            ProgressView("Finding your server…")
                .task { await discover() }
        }
    }

    private var serverPickerView: some View {
        NavigationStack {
            List(serverConnection.availableServers) { server in
                Button {
                    serverConnection.selectServer(server)
                } label: {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.tint)
                            .font(.title2)

                        VStack(alignment: .leading) {
                            Text(server.name)
                                .font(.headline)
                            Text(connectionLabel(for: server))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Select Server")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign Out", role: .destructive) { signOut() }
                }
            }
        }
    }

    private func connectionLabel(for server: PlexServer) -> String {
        if let active = server.connections.first(where: { $0.uri == server.uri }) {
            if active.relay == true { return "Relay" }
            if active.local == true { return "Local" }
            return "Remote"
        }
        return server.uri
    }

    private func discover() async {
        guard let token = authToken else { return }
        do {
            try await serverConnection.autoDiscover(authToken: token, client: client)
        } catch {
            discoveryError = error.localizedDescription
        }
    }

    private var mainTabView: some View {
        let tabs = TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: "home") {
                NavigationStack {
                    HomeView()
                        .navigationDestinations()
                        .accountToolbar(signOut: signOut)
                }
            }

            Tab("Artists", systemImage: "music.mic", value: "artists") {
                NavigationStack(path: $artistsPath) {
                    ArtistsView()
                        .navigationDestinations()
                }
            }

            Tab("Albums", systemImage: "square.stack", value: "albums") {
                NavigationStack(path: $albumsPath) {
                    AllAlbumsView()
                        .navigationDestinations()
                }
            }

            Tab("Songs", systemImage: "music.note", value: "songs") {
                NavigationStack {
                    AllSongsView()
                        .navigationDestinations()
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: "search", role: .search) {
                NavigationStack {
                    SearchView()
                        .navigationDestinations()
                }
            }
        }

        let base = tabs
            .tabViewBottomAccessory {
                MiniPlayerView(showNowPlaying: $showNowPlaying) { panel in
                    openNowPlaying(panel)
                }
            }
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView(startPanel: nowPlayingStartPanel) { target in
                    pendingNavigation = target
                }
                .environment(player)
                .onDisappear {
                    nowPlayingStartPanel = .none
                }
            }

        let withNavigation = base
            .onChange(of: showNowPlaying) { oldValue, newValue in
                if oldValue && !newValue, let target = pendingNavigation {
                    pendingNavigation = nil
                    // Delay to let the fullScreenCover dismiss animation complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        navigateToTarget(target)
                    }
                }
            }

        if UIDevice.current.userInterfaceIdiom == .pad {
            return AnyView(withNavigation.tabViewStyle(.sidebarAdaptable))
        } else {
            return AnyView(withNavigation)
        }
    }

    private func signOut() {
        authToken = nil
        KeychainHelper.delete(forKey: "plexAuthToken")
        serverConnection.disconnect()
        // Cache clearing is handled by disconnect() — no duplicate clearing needed
    }

    private func openNowPlaying(_ panel: NowPlayingStartPanel = .none) {
        nowPlayingStartPanel = panel
        showNowPlaying = true
    }

    private func navigateToTarget(_ target: PlexMetadata) {
        // Disable all animations to prevent Liquid Glass morph crash
        UIView.setAnimationsEnabled(false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if target.type == "artist" {
                artistsPath = NavigationPath()
                selectedTab = "artists"
            } else {
                albumsPath = NavigationPath()
                selectedTab = "albums"
            }
        }
        // Wait for the tab switch to settle, then push the destination
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIView.setAnimationsEnabled(true)
            if target.type == "artist" {
                artistsPath.append(target)
            } else {
                albumsPath.append(target)
            }
        }
    }
}

// MARK: - Account Toolbar

private extension View {
    func accountToolbar(signOut: @escaping () -> Void) -> some View {
        self.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView(onSignOut: signOut)
                } label: {
                    Image(systemName: "gear")
                }
                .tint(.primary)
            }
        }
    }
}

// MARK: - Navigation Destinations

private extension View {
    func navigationDestinations() -> some View {
        self
            .navigationDestination(for: PlexMetadata.self) { item in
                switch item.type {
                case "artist":
                    ArtistDetailView(artist: item)
                case "album":
                    AlbumDetailView(album: item)
                default:
                    AlbumDetailView(album: item)
                }
            }
            .navigationDestination(for: PlexPlaylist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
    }

}

#Preview {
    ContentView()
        .environment(AudioPlayerService())
}
