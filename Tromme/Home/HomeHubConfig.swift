import Foundation

enum HomeHubConfig {
    static let orderKey = "homeHubOrder"
    static let enabledKey = "homeHubsEnabled"
    static let hiddenSectionsKey = "homeSectionsHidden"
    static let recentlyPlayedLevelKey = "recentlyPlayedLevel"

    static let favorites = Hub(hubIdentifier: "builtin.favorites", title: "Favorites", type: "builtin", size: nil, metadata: nil)
    static let playlists = Hub(hubIdentifier: "builtin.playlists", title: "Playlists", type: "builtin", size: nil, metadata: nil)

    static func isBuiltin(_ hub: Hub) -> Bool {
        hub.type == "builtin"
    }

    static func isEnabled(_ hub: Hub, enabledRaw: String, hiddenRaw: String) -> Bool {
        guard let id = stableID(for: hub) else { return false }
        return isBuiltin(hub) ? !ids(hiddenRaw).contains(id) : ids(enabledRaw).contains(id)
    }

    static func settingEnabled(_ hub: Hub, _ isOn: Bool, enabledRaw: inout String, hiddenRaw: inout String) {
        guard let id = stableID(for: hub) else { return }
        if isBuiltin(hub) {
            var hidden = ids(hiddenRaw).filter { $0 != id }
            if !isOn { hidden.append(id) }
            hiddenRaw = raw(hidden)
        } else {
            var enabled = ids(enabledRaw).filter { $0 != id }
            if isOn { enabled.append(id) }
            enabledRaw = raw(enabled)
        }
    }

    private static func flattenedIdentifier(_ hub: Hub) -> String {
        (hub.hubIdentifier ?? "").lowercased().replacingOccurrences(of: ".", with: "")
    }

    static func isRecentlyPlayed(_ hub: Hub) -> Bool {
        let flattened = flattenedIdentifier(hub)
        return flattened.contains("recentplayed") || flattened.contains("recentlyplayed")
    }

    static func recentlyPlayedHub(_ hub: Hub, level: String, tracks: [PlexMetadata]) -> Hub {
        if level == "artists" {
            var seen = Set<String>()
            let artists: [PlexMetadata] = tracks.compactMap { track in
                guard let key = track.grandparentRatingKey, let name = track.grandparentTitle,
                      seen.insert(key).inserted else { return nil }
                return PlexMetadata(ratingKey: key, title: name, type: "artist", thumb: track.grandparentThumb)
            }
            return Hub(hubIdentifier: hub.hubIdentifier, context: hub.context, title: hub.title, type: "artist", size: artists.count, metadata: artists)
        }
        return Hub(hubIdentifier: hub.hubIdentifier, context: hub.context, title: hub.title, type: "track", size: tracks.count, metadata: tracks)
    }

    static func ids(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }

    static func raw(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    static var enabledIDs: Set<String> {
        Set(ids(UserDefaults.standard.string(forKey: enabledKey) ?? ""))
    }

    private static func templatePrefix(of hub: Hub) -> String? {
        let prepositions: Set<String> = ["in", "by", "from", "during", "for", "on", "to", "of"]
        let words = (hub.title ?? "").split(separator: " ")
        guard let index = words.indices.first(where: { $0 >= 1 && $0 < words.count - 1 && prepositions.contains(words[$0].lowercased()) }) else { return nil }
        return words[...index].joined(separator: " ")
    }

    static func stableID(for hub: Hub) -> String? {
        if let prefix = templatePrefix(of: hub) { return "title:" + prefix.lowercased() }
        guard let identifier = hub.context ?? hub.hubIdentifier else { return nil }
        let kept = identifier.split(separator: ".", omittingEmptySubsequences: false)
            .filter { $0.isEmpty || !$0.allSatisfy(\.isNumber) }
        return kept.joined(separator: ".")
    }

    static func displayTitle(for hub: Hub) -> String {
        if let prefix = templatePrefix(of: hub) { return prefix + "…" }
        return hub.title ?? ""
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

    static func seedDefaultsIfNeeded(from hubs: [Hub]) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) == nil else { return }
        let recents = hubs.filter { hub in
            let flattened = flattenedIdentifier(hub)
            return ["recentadded", "recentlyadded"].contains { flattened.contains($0) } || isRecentlyPlayed(hub)
        }
        let ids = recents.compactMap(stableID(for:))
        defaults.set(raw(ids), forKey: enabledKey)
        defaults.set(raw(ids), forKey: orderKey)
    }

    static func rowType(of hub: Hub) -> String {
        hub.type ?? hub.metadata?.first?.type ?? ""
    }

    private static func position(of hub: Hub, in order: [String]) -> Int {
        let id = stableID(for: hub) ?? ""
        if let index = order.firstIndex(of: id) { return index }
        return id == favorites.hubIdentifier ? -1 : Int.max
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
