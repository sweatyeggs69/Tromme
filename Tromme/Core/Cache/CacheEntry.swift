import Foundation
import CryptoKit

final class CacheEntry: NSObject, Codable {
    let data: Data
    let timestamp: Date

    init(data: Data, timestamp: Date) {
        self.data = data
        self.timestamp = timestamp
    }

    func decode<T: Decodable>(as type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }
}
