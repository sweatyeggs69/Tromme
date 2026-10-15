import Foundation
import CryptoKit

struct CachedResult<T: Sendable>: Sendable {
    let value: T
    let isStale: Bool
}
