import SwiftUI

@main
struct TrommeApp: App {
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
    }
}
