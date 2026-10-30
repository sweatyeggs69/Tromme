import Foundation

enum AnimatedArtworkEntitlement {
    static var isUnlocked: Bool {
        PlusStore.cachedIsPlus
    }

    static let settingKey = "animatedArtworkEnabled"

    static var isLowDataMode: Bool {
        NetworkStatus.shared.isConstrained
    }

    static var isEnabled: Bool {
        isUnlocked && !isLowDataMode && (UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true)
    }
}
