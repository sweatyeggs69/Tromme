import Foundation

enum HomeHubConfig {
    static let orderKey = "homeHubOrder"
    static let enabledKey = "homeHubsEnabled"

    static func ids(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }

    static func raw(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    static var enabledIDs: Set<String> {
        Set(ids(UserDefaults.standard.string(forKey: enabledKey) ?? ""))
    }

    static func stableID(for hub: Hub) -> String? {
        guard let identifier = hub.hubIdentifier else { return nil }
        guard let range = identifier.range(of: #"\.\d+$"#, options: .regularExpression) else { return identifier }
        return String(identifier[..<range.lowerBound])
    }

    static func isSupported(_ hub: Hub) -> Bool {
        guard stableID(for: hub) != nil, hub.title != nil else { return false }
        guard ["track", "album", "artist"].contains(rowType(of: hub)) else { return false }
        let flattened = (hub.hubIdentifier ?? "").lowercased().replacingOccurrences(of: ".", with: "")
        let duplicates = ["recentadded", "recentlyadded", "recentplayed", "recentlyplayed"]
        return !duplicates.contains { flattened.contains($0) }
    }

    static func rowType(of hub: Hub) -> String {
        hub.type ?? hub.metadata?.first?.type ?? ""
    }

    static func ordered(_ hubs: [Hub], by order: [String]) -> [Hub] {
        hubs.enumerated().sorted { lhs, rhs in
            let l = order.firstIndex(of: stableID(for: lhs.element) ?? "") ?? Int.max
            let r = order.firstIndex(of: stableID(for: rhs.element) ?? "") ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }
        .map(\.element)
    }
}
