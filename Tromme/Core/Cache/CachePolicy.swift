import Foundation
import CryptoKit

enum CachePolicy: Sendable {
    case library
    case detail
    case albumInfo
    case userContent
    case homeContent
    case search

    var memoryTTL: TimeInterval {
        switch self {
        case .library:     return 14400     // 4 hours
        case .detail:      return 7200      // 2 hours
        case .albumInfo:   return 7200      // 2 hours
        case .userContent: return 3600      // 1 hour
        case .homeContent: return 1800      // 30 min
        case .search:      return 600       // 10 min
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
        }
    }
}
