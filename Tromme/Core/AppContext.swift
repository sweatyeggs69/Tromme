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

    private var serverObservationTask: Task<Void, Never>?

    private init() {
        if let server = serverConnection.currentServer {
            audioPlayer.configure(server: server, client: plexClient)
        }
        // Re-configure the player whenever the server connection changes (e.g. after reprobe
        // finds a better URI). Without this, CarPlay playback fails when the stored server URI
        // is stale — reprobe updates serverConnection.currentServer but the player keeps the
        // old URI, and all stream requests fail until the phone app UI fires its own onChange.
        serverObservationTask = Task {
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.serverConnection.currentServer
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                if let server = self.serverConnection.currentServer {
                    self.audioPlayer.configure(server: server, client: self.plexClient)
                }
            }
        }
    }
}
