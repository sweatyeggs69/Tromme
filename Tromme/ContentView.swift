import SwiftUI

struct ContentView: View {
    @Environment(\.serverConnection) private var serverConnection
    @Environment(AudioPlayerService.self) private var player

    @Environment(\.plexClient) private var client

    @State private var authToken: String? = UserDefaults.standard.string(forKey: "plexAuthToken")
    @State private var showNowPlaying = false
    @State private var discoveryError: String?

    var body: some View {
        Group {
            if authToken == nil {
                LoginView { token in
                    authToken = token
                }
            } else if serverConnection.currentServer == nil {
                serverDiscoveryView
            } else if serverConnection.currentLibrarySectionId == nil {
                LibraryPickerView {
                    // Library selected
                }
            } else {
                mainTabView
            }
        }
        .appGlobalListStyle()
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

    private func discover() async {
        guard let token = authToken else { return }
        do {
            try await serverConnection.autoDiscover(authToken: token, client: client)
        } catch {
            discoveryError = error.localizedDescription
        }
    }

    private var mainTabView: some View {
        let tabs = TabView {
            Tab("Home", systemImage: "house.fill") {
                NavigationStack {
                    HomeView()
                        .navigationDestinations()
                        .accountToolbar(signOut: signOut)
                }
            }

            Tab("Artists", systemImage: "music.mic") {
                NavigationStack {
                    ArtistsView()
                        .navigationDestinations()
                }
            }

            Tab("Albums", systemImage: "square.stack") {
                NavigationStack {
                    AllAlbumsView()
                        .navigationDestinations()
                }
            }

            Tab("Songs", systemImage: "music.note") {
                NavigationStack {
                    AllSongsView()
                        .navigationDestinations()
                }
            }

            Tab(role: .search) {
                NavigationStack {
                    SearchView()
                        .navigationDestinations()
                }
            }
        }

        return tabs
            .tabViewBottomAccessory {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
            }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environment(player)
        }
    }

    private func signOut() {
        authToken = nil
        UserDefaults.standard.removeObject(forKey: "plexAuthToken")
        serverConnection.disconnect()
        Task {
            await LibraryCache.shared.clearAll()
            await ImageCache.shared.clearAll()
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
