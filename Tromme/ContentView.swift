import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player
    @Environment(NetworkStatus.self) private var network

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
            if !hasAuthenticatedContext {
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
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            refreshAuthTokenFromKeychainIfNeeded()
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
            if network.isConnected {
                Tab("Home", systemImage: "house.fill", value: "home") {
                    NavigationStack {
                        HomeView()
                            .navigationDestinations()
                            .settingsToolbar(alwaysVisible: true, signOut: signOut)
                    }
                }
            }

            Tab("Artists", systemImage: "music.mic", value: "artists") {
                NavigationStack(path: $artistsPath) {
                    ArtistsView()
                        .navigationDestinations()
                        .settingsToolbar(signOut: signOut)
                }
            }

            Tab("Albums", systemImage: "square.stack", value: "albums") {
                NavigationStack(path: $albumsPath) {
                    AllAlbumsView()
                        .navigationDestinations()
                        .settingsToolbar(signOut: signOut)
                }
            }

            Tab("Songs", systemImage: "music.note", value: "songs") {
                NavigationStack {
                    AllSongsView()
                        .navigationDestinations()
                        .settingsToolbar(signOut: signOut)
                }
            }

            if UIDevice.current.userInterfaceIdiom == .pad {
                Tab("Search", systemImage: "magnifyingglass", value: "search") {
                    NavigationStack {
                        SearchView()
                            .navigationDestinations()
                    }
                }
            } else {
                Tab("Search", systemImage: "magnifyingglass", value: "search", role: .search) {
                    NavigationStack {
                        SearchView()
                            .navigationDestinations()
                    }
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

        return base
            .onChange(of: network.isConnected) { _, isConnected in
                if !isConnected && selectedTab == "home" {
                    selectedTab = "artists"
                }
            }
            .onChange(of: showNowPlaying) { oldValue, newValue in
                if oldValue && !newValue, let target = pendingNavigation {
                    pendingNavigation = nil
                    // Wait for the fullScreenCover dismiss animation to complete before navigating.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        navigateToTarget(target)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !network.isConnected {
                    offlineBanner
                }
            }
    }

    private var offlineBanner: some View {
        Label("Offline", systemImage: "wifi.slash")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar, in: Capsule())
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut, value: network.isConnected)
    }

    private func signOut() {
        player.resetPlayback()
        authToken = nil
        KeychainHelper.delete(forKey: "plexAuthToken")
        serverConnection.disconnect()
        // Cache clearing is handled by disconnect() — no duplicate clearing needed
    }

    private var hasAuthenticatedContext: Bool {
        authToken != nil || (serverConnection.currentServer != nil && serverConnection.currentLibrarySectionId != nil)
    }

    private func refreshAuthTokenFromKeychainIfNeeded() {
        guard authToken == nil else { return }
        authToken = KeychainHelper.load(forKey: "plexAuthToken")
    }

    private func openNowPlaying(_ panel: NowPlayingStartPanel = .none) {
        nowPlayingStartPanel = panel
        showNowPlaying = true
    }

    private func navigateToTarget(_ target: PlexMetadata) {
        // Switch tabs and reset path without animation to prevent Liquid Glass morph crash.
        withAnimation(.none) {
            if target.type == "artist" {
                artistsPath = NavigationPath()
                selectedTab = "artists"
            } else {
                albumsPath = NavigationPath()
                selectedTab = "albums"
            }
        }
        // Let the tab switch settle before pushing the destination.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if target.type == "artist" {
                artistsPath.append(target)
            } else {
                albumsPath.append(target)
            }
        }
    }
}

// MARK: - Settings Toolbar
//
// On the Home tab (always online), the gear appears in the trailing position.
// On offline-capable tabs, the gear only appears when offline, in the leading position
// so it doesn't conflict with per-view trailing toolbar items.

private struct SettingsToolbarModifier: ViewModifier {
    @Environment(NetworkStatus.self) private var network
    let alwaysVisible: Bool
    let signOut: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            if alwaysVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(onSignOut: signOut)
                    } label: {
                        Image(systemName: "gear")
                    }
                    .tint(.primary)
                }
            } else if !network.isConnected {
                ToolbarItem(placement: .topBarLeading) {
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
}

private extension View {
    /// Adds a gear → Settings link. Pass `alwaysVisible: true` for the Home tab;
    /// offline-only tabs pass `false` so the gear only appears when disconnected.
    func settingsToolbar(alwaysVisible: Bool = false, signOut: @escaping () -> Void) -> some View {
        modifier(SettingsToolbarModifier(alwaysVisible: alwaysVisible, signOut: signOut))
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
