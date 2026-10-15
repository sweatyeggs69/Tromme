import Foundation

/// Gate for animated artwork, a Tromme+ subscription feature.
/// Unlocked by the Tromme Plus subscription (see `PlusStore`).
enum AnimatedArtworkEntitlement {
    static var isUnlocked: Bool {
        PlusStore.cachedIsPlus
    }

    /// `@AppStorage` key for the Settings > Interface toggle (default on).
    static let settingKey = "animatedArtworkEnabled"

    /// Tromme+ and the user's toggle both allow it. When false, nothing is looked
    /// up or played and only static artwork shows.
    static var isEnabled: Bool {
        isUnlocked && (UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true)
    }
}
