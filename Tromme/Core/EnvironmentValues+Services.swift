import SwiftUI

extension EnvironmentValues {
    var serverConnection: ServerConnectionManager {
        get { self[ServerConnectionManagerKey.self] }
        set { self[ServerConnectionManagerKey.self] = newValue }
    }

    var plexClient: PlexAPIClient {
        get { self[PlexAPIClientKey.self] }
        set { self[PlexAPIClientKey.self] = newValue }
    }

    /// Accent color as a Color, for explicit tinting of Menu and contextMenu.
    var appAccentColor: Color {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }
}

private struct ServerConnectionManagerKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = ServerConnectionManager()
}

private struct PlexAPIClientKey: EnvironmentKey {
    static let defaultValue = PlexAPIClient()
}

private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue: Color = AppIconOption.all[0].accentColor
}
