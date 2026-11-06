import Foundation

enum HomeHubConfig {
    static let orderKey = "homeHubOrder"
    static let hiddenSectionsKey = "homeSectionsHidden"
    static let recentlyPlayedLevelKey = "recentlyPlayedLevel"

    static let favorites = Hub(hubIdentifier: "builtin.favorites", title: "Favorites", type: "builtin", size: nil, metadata: nil)
    static let playlists = Hub(hubIdentifier: "builtin.playlists", title: "Playlists", type: "builtin", size: nil, metadata: nil)

    static func isBuiltin(_ hub: Hub) -> Bool {
        hub.type == "builtin"
    }

    static func isEnabled(_ hub: Hub, hiddenRaw: String) -> Bool {
        guard let id = stableID(for: hub) else { return false }
        return !ids(hiddenRaw).contains(id)
    }

    static func setEnabled(_ hub: Hub, _ isOn: Bool, hiddenRaw: inout String) {
        guard let id = stableID(for: hub) else { return }
        var hidden = ids(hiddenRaw).filter { $0 != id }
        if !isOn { hidden.append(id) }
        hiddenRaw = raw(hidden)
    }

    private static func flattenedIdentifier(_ hub: Hub) -> String {
        (hub.hubIdentifier ?? "").lowercased().replacingOccurrences(of: ".", with: "")
    }

    static func isRecentlyPlayed(_ hub: Hub) -> Bool {
        let flattened = flattenedIdentifier(hub)
        return flattened.contains("recentplayed") || flattened.contains("recentlyplayed")
    }

    static func isRecentlyAdded(_ hub: Hub) -> Bool {
        let flattened = flattenedIdentifier(hub)
        return flattened.contains("recentadded") || flattened.contains("recentlyadded")
    }

    static func title(for hub: Hub) -> String {
        if isRecentlyPlayed(hub) { return "Recently Played" }
        if isRecentlyAdded(hub) { return "Recently Added" }
        return hub.title ?? ""
    }

    static func recentlyPlayedHub(_ hub: Hub, level: String, recentTracks: [PlexMetadata]) -> Hub {
        let items = recentTracks.isEmpty ? (hub.metadata ?? []) : recentTracks
        let itemType = recentTracks.isEmpty ? rowType(of: hub) : "track"
        if level == "artists" {
            var seen = Set<String>()
            let artists: [PlexMetadata] = items.compactMap { item -> PlexMetadata? in
                let key: String?
                let name: String?
                let thumb: String?
                switch itemType {
                case "artist":
                    key = item.ratingKey; name = item.title; thumb = item.thumb
                case "album":
                    key = item.parentRatingKey; name = item.parentTitle; thumb = item.parentThumb
                default:
                    key = item.grandparentRatingKey; name = item.grandparentTitle; thumb = item.grandparentThumb
                }
                guard let key, let name, seen.insert(key).inserted else { return nil }
                return PlexMetadata(ratingKey: key, title: name, type: "artist", thumb: thumb)
            }
            return Hub(hubIdentifier: hub.hubIdentifier, context: hub.context, title: hub.title, type: "artist", size: artists.count, metadata: artists)
        }
        guard itemType == "track" else { return hub }
        return Hub(hubIdentifier: hub.hubIdentifier, context: hub.context, title: hub.title, type: "track", size: items.count, metadata: items)
    }

    static func ids(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }

    static func raw(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    private static func templatePrefix(of hub: Hub) -> String? {
        let prepositions: Set<String> = ["in", "by", "from", "during", "for", "on", "to", "of"]
        let words = (hub.title ?? "").split(separator: " ")
        guard let index = words.indices.first(where: { $0 >= 1 && $0 < words.count - 1 && prepositions.contains(words[$0].lowercased()) }) else { return nil }
        return words[...index].joined(separator: " ")
    }

    static func stableID(for hub: Hub) -> String? {
        if !isRecentlyPlayed(hub), !isRecentlyAdded(hub), let prefix = templatePrefix(of: hub) {
            return "title:" + prefix.lowercased()
        }
        guard let identifier = hub.context ?? hub.hubIdentifier else { return nil }
        let kept = identifier.split(separator: ".", omittingEmptySubsequences: false)
            .filter { $0.isEmpty || !$0.allSatisfy(\.isNumber) }
        return kept.joined(separator: ".")
    }

    static func displayTitle(for hub: Hub) -> String {
        if !isRecentlyPlayed(hub), !isRecentlyAdded(hub), let prefix = templatePrefix(of: hub) { return prefix + "…" }
        return title(for: hub)
    }

    static func uniqueByKind(_ hubs: [Hub]) -> [Hub] {
        var seen = Set<String>()
        return hubs.filter { hub in
            guard let id = stableID(for: hub) else { return false }
            return seen.insert(id).inserted
        }
    }

    static func isSupported(_ hub: Hub) -> Bool {
        guard stableID(for: hub) != nil, hub.title != nil else { return false }
        return ["track", "album", "artist"].contains(rowType(of: hub))
    }

    static func rowType(of hub: Hub) -> String {
        hub.type ?? hub.metadata?.first?.type ?? ""
    }

    private static func position(of hub: Hub, in order: [String]) -> Int {
        let id = stableID(for: hub) ?? ""
        if let index = order.firstIndex(of: id) { return index }
        if id == favorites.hubIdentifier { return -2 }
        if id == playlists.hubIdentifier { return -1 }
        return Int.max
    }

    static func ordered(_ hubs: [Hub], by order: [String]) -> [Hub] {
        hubs.enumerated().sorted { lhs, rhs in
            let l = position(of: lhs.element, in: order)
            let r = position(of: rhs.element, in: order)
            return l == r ? lhs.offset < rhs.offset : l < r
        }
        .map(\.element)
    }
}
