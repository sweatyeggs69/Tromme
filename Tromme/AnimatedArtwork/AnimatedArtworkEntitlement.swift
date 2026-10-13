import Foundation

/// Single switch for the Tromme+ gate. Debug builds are unlocked for testing;
/// release builds stay locked until a Tromme+ purchase check is wired in here.
enum AnimatedArtworkEntitlement {
    static let enabledKey = "animatedArtworkEnabled"

    static var isUnlocked: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// True when the user has the toggle on and owns Tromme+.
    static var isActive: Bool {
        isUnlocked && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }
}
