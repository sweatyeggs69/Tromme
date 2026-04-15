import SwiftUI
import UIKit

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
                .onChange(of: serverConnection.currentServer, initial: true) { _, server in
                    if let server {
                        audioPlayer.configure(server: server, client: plexClient)
                    }
                }
                .task {
                    // Warm cache on launch if already signed in
                    guard let server = serverConnection.currentServer,
                          let sectionId = serverConnection.currentLibrarySectionId else { return }
                    serverConnection.warmCache(server: server, sectionId: sectionId, client: plexClient)
                }
                .task {
                    await observeMemoryWarnings()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await ImageCache.shared.clearMemory() }
            }
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
                    await plexClient.warmCache(server: server, sectionId: sectionId)
                }
            }
        }
    }

    private func observeMemoryWarnings() async {
        for await _ in NotificationCenter.default.notifications(
            named: UIApplication.didReceiveMemoryWarningNotification
        ) {
            await ImageCache.shared.clearMemory()
        }
    }
}
