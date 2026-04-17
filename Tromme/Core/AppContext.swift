import Foundation

/// Lightweight singleton that lets non-SwiftUI code (e.g. CarPlay scene delegate)
/// access the same shared service instances that TrommeApp creates.
@MainActor
final class AppContext {
    static let shared = AppContext()

    var serverConnection: ServerConnectionManager?
    var plexClient: PlexAPIClient?
    var audioPlayer: AudioPlayerService?

    private init() {}
}
