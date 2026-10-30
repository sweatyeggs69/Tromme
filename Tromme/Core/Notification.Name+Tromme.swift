import Foundation
import CryptoKit

extension Notification.Name {
    static let favoritesDidChange = Notification.Name("TrommeFavoritesDidChange")
    static let libraryContentDidChange = Notification.Name("TrommeLibraryContentDidChange")
    static let recentlyPlayedDidChange = Notification.Name("TrommeRecentlyPlayedDidChange")

    static func postLibraryContentDidChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .libraryContentDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .libraryContentDidChange, object: nil)
            }
        }
    }
}
