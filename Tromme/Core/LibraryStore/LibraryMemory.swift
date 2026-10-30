import Foundation
import os

final class LibraryMemory: Sendable {
    private let lists = OSAllocatedUnfairLock<[String: [PlexMetadata]]>(initialState: [:])

    private func key(_ scope: String, _ kind: Int) -> String { "\(scope)#\(kind)" }

    func items(scope: String, kind: Int) -> [PlexMetadata]? {
        lists.withLock { $0[key(scope, kind)] }
    }

    func set(_ items: [PlexMetadata], scope: String, kind: Int) {
        lists.withLock { $0[key(scope, kind)] = items }
    }

    func remove(scope: String, kind: Int) {
        lists.withLock { _ = $0.removeValue(forKey: key(scope, kind)) }
    }

    func removeAll() {
        lists.withLock { $0.removeAll() }
    }
}
