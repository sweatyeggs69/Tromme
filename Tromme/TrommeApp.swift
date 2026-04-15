import SwiftUI

@main
struct TrommeApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var serverConnection = ServerConnectionManager()
    @State private var plexClient = PlexAPIClient()
    @State private var audioPlayer = AudioPlayerService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.serverConnection, serverConnection)
                .environment(\.plexClient, plexClient)
                .environment(audioPlayer)
                .tint(AppStyle.Colors.tint)
                .onChange(of: serverConnection.currentServer, initial: true) { _, server in
                    if let server {
                        audioPlayer.configure(server: server, client: plexClient)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    guard let server = serverConnection.currentServer,
                          let sectionId = serverConnection.currentLibrarySectionId else { return }
                    // Check if library has actually changed before rebuilding cache
                    guard let sections = try? await plexClient.getLibrarySections(server: server),
                          let section = sections.first(where: { $0.key == sectionId }),
                          let serverUpdatedAt = section.updatedAt else { return }
                    let lastUpdatedAt = UserDefaults.standard.integer(forKey: "lastLibraryUpdatedAt")
                    guard serverUpdatedAt > lastUpdatedAt else { return }
                    UserDefaults.standard.set(serverUpdatedAt, forKey: "lastLibraryUpdatedAt")
                    await LibraryCache.shared.clearAll()
                    _ = try? await plexClient.cachedTracks(server: server, sectionId: sectionId)
                    _ = try? await plexClient.cachedAlbums(server: server, sectionId: sectionId)
                }
            }
        }
    }
}
