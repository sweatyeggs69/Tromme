import Foundation

/// Gate for animated artwork, a Tromme+ subscription feature.
/// Wire `isUnlocked` to the Tromme+ entitlement once the purchase flow exists.
enum AnimatedArtworkEntitlement {
    static var isUnlocked: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// `@AppStorage` key for the Settings > Interface toggle (default on).
    static let settingKey = "animatedArtworkEnabled"

    /// Tromme+ and the user's toggle both allow it. When false, nothing is looked
    /// up or played and only static artwork shows.
    static var isEnabled: Bool {
        isUnlocked && (UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true)
    }
}
