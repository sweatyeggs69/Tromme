import SwiftUI
import UIKit
import CryptoKit

actor ArtworkColorPersistence {
    func load(from fileURL: URL) -> [String: [CGFloat]] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: [CGFloat]].self, from: data) else {
            return [:]
        }
        return entries
    }

    func save(_ entries: [String: [CGFloat]], to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
