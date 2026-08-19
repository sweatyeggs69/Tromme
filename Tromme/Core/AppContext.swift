import Foundation

/// Lightweight singleton that lets non-SwiftUI code (e.g. CarPlay scene delegate)
/// access the same shared service instances that TrommeApp creates.
///
/// Services are eagerly initialized so they are available as soon as any scene
/// (including CarPlay) first accesses the singleton — even before the main
/// SwiftUI WindowGroup has appeared.
@MainActor
final class AppContext {
    static let shared = AppContext()

    let serverConnection = ServerConnectionManager()
    let plexClient = PlexAPIClient()
    let audioPlayer = AudioPlayerService()
    let downloadManager = DownloadManager()

    private init() {
        if let server = serverConnection.currentServer {
            audioPlayer.configure(server: server, client: plexClient)
        }
    }
}
