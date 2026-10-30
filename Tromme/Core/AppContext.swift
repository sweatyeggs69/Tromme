import Foundation

@MainActor
final class AppContext {
    static let shared = AppContext()

    let serverConnection = ServerConnectionManager()
    let plexClient = PlexAPIClient()
    let audioPlayer = AudioPlayerService()
    let downloadManager = DownloadManager()
    let trackMarkers = TrackMarkerStore()

    private var serverObservationTask: Task<Void, Never>?

    private init() {
        if let server = serverConnection.currentServer {
            // Deferred: configure() can synchronously reach code (e.g.
            // maybeRefillInfiniteQueueIfNeeded) that touches AppContext.shared,
            // which would re-enter this initializer's dispatch_once and trap.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioPlayer.configure(server: server, client: self.plexClient)
            }
        }
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
