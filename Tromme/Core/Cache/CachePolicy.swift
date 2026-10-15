import Foundation
import CryptoKit

/// Per-data-type freshness windows. Different data changes at different rates,
/// so a one-size-fits-all TTL leaves some data stale and over-fetches others.
enum CachePolicy: Sendable {
    /// Large, rarely-changing lists (all artists, all albums, all tracks).
    /// Memory: 4 hours, Disk: 30 days.
    case library
    /// Detail pages, children, top tracks — moderate change frequency.
    /// Memory: 2 hours, Disk: 7 days.
    case detail
    /// Album info/summary payloads for album detail.
    /// Memory: 2 hours, Disk: 24 hours.
    case albumInfo
    /// Playlists, favorites — user-editable, changes more often.
    /// Memory: 1 hour, Disk: 3 days.
    case userContent
    /// Home-screen dynamic lists (recently played, recently added) — always stale on cold launch.
    /// Memory: 30 min, Disk: 30 min.
    case homeContent
    /// Search results — short-lived, mostly just deduplication.
    /// Memory: 10 min, Disk: 4 hours.
    case search
    /// Last.fm artist top-tracks — changes very slowly.
    /// Memory: 4 hours, Disk: 7 days.
    case lastFM

    var memoryTTL: TimeInterval {
        switch self {
        case .library:     return 14400     // 4 hours
        case .detail:      return 7200      // 2 hours
        case .albumInfo:   return 7200      // 2 hours
        case .userContent: return 3600      // 1 hour
        case .homeContent: return 1800      // 30 min
        case .search:      return 600       // 10 min
        case .lastFM:      return 14400     // 4 hours
        }
    }

    var diskTTL: TimeInterval {
        switch self {
        case .library:      return 2_592_000 // 30 days
        case .detail:       return 604_800   // 7 days
        case .albumInfo:    return 86_400    // 24 hours
        case .userContent:  return 259_200   // 3 days
        case .homeContent:  return 1800      // 30 min — always stale on cold launch
        case .search:       return 14400     // 4 hours
        case .lastFM:       return 604_800   // 7 days
        }
    }
}
