import AppIntents

struct MusicItemQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MusicItemEntity] {
        await MusicItemResolver.entities(for: identifiers)
    }

    func entities(matching string: String) async throws -> [MusicItemEntity] {
        try await MusicItemResolver.search(string)
    }

    func suggestedEntities() async throws -> [MusicItemEntity] {
        []
    }
}
