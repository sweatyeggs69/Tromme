import Foundation

extension PlexAPIClient {
    func updateLibraryItem(
        server: PlexServer,
        sectionId: String,
        type: Int,
        ratingKey: String,
        fields: [(name: String, value: String)]
    ) async throws {
        var parts = ["type=\(type)", "id=\(ratingKey)"]
        parts += fields.map { "\($0.name)=\(Self.encodeQueryValue($0.value))" }
        do {
            _ = try await rawServerRequest(
                server: server,
                path: "/library/sections/\(sectionId)/all?\(parts.joined(separator: "&"))",
                method: "PUT"
            )
        } catch PlexAPIError.serverError(400) {
            let plain = fields.filter { $0.name.hasSuffix(".value") && !$0.name.hasPrefix("artist.") && !$0.name.hasPrefix("album.") }
            guard !plain.isEmpty, plain.count == fields.filter({ $0.name.hasSuffix(".value") }).count else {
                throw PlexAPIError.serverError(400)
            }
            let query = plain.map { "\($0.name.dropLast(".value".count))=\(Self.encodeQueryValue($0.value))" }
            _ = try await rawServerRequest(
                server: server,
                path: "/library/metadata/\(ratingKey)?\(query.joined(separator: "&"))",
                method: "PUT"
            )
        }
    }

    func updateTags(
        server: PlexServer,
        sectionId: String,
        type: Int,
        ratingKey: String,
        changes: [(kind: TagKind, added: [String], removed: [String])]
    ) async throws {
        var parts = ["type=\(type)", "id=\(ratingKey)"]
        for change in changes {
            let name = change.kind.rawValue
            for (index, tag) in change.added.enumerated() {
                parts.append("\(name)%5B\(index)%5D.tag.tag=\(Self.encodeQueryValue(tag))")
            }
            if !change.removed.isEmpty {
                let removed = change.removed.map(Self.encodeQueryValue).joined(separator: ",")
                parts.append("\(name)%5B%5D.tag.tag-=\(removed)")
            }
            parts.append("\(name).locked=1")
        }
        guard !changes.isEmpty else { return }
        _ = try await rawServerRequest(
            server: server,
            path: "/library/sections/\(sectionId)/all?\(parts.joined(separator: "&"))",
            method: "PUT"
        )
    }

    func getTagSuggestions(server: PlexServer, sectionId: String, type: Int) async -> [TagKind: [String]] {
        guard let filters: PlexTagListResponse = try? await serverRequest(
            server: server,
            path: "/library/sections/\(sectionId)/filters?type=\(type)"
        ) else { return [:] }
        var result: [TagKind: [String]] = [:]
        for kind in TagKind.allCases {
            guard let key = filters.mediaContainer.entries.first(where: { $0.filter == kind.rawValue })?.key,
                  let list: PlexTagListResponse = try? await serverRequest(server: server, path: key) else { continue }
            let names = list.mediaContainer.entries.compactMap { $0.tag ?? $0.title }
            result[kind] = Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return result
    }

    private static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}
