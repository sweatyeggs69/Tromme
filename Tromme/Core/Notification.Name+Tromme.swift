import Foundation
import CryptoKit

extension Notification.Name {
    static let favoritesDidChange = Notification.Name("TrommeFavoritesDidChange")
    /// Posted by smartRefresh when it detects that the server library has changed.
    /// Listeners (e.g. HomeView) should reload their content when this fires.
    static let libraryContentDidChange = Notification.Name("TrommeLibraryContentDidChange")
    /// Posted after a finished play is reported to the server so the home screen refreshes recently played.
    static let recentlyPlayedDidChange = Notification.Name("TrommeRecentlyPlayedDidChange")

    /// Posts `libraryContentDidChange` on the main thread; observers update published view state.
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
