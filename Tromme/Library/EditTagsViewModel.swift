import Foundation
import Observation

@Observable @MainActor
final class EditTagsViewModel {
    let item: PlexMetadata
    var tags: [TagKind: [String]]
    var drafts: [TagKind: String] = [:]
    private(set) var isSaving = false
    var errorMessage: String?

    private let original: [TagKind: [String]]

    init(item: PlexMetadata) {
        self.item = item
        let current = Dictionary(uniqueKeysWithValues: TagKind.allCases.map { ($0, $0.tags(in: item)) })
        original = current
        tags = current
    }

    var hasChanges: Bool {
        TagKind.allCases.contains { kind in
            tags[kind] != original[kind] || !cleaned(drafts[kind]).isEmpty
        }
    }

    func commitDraft(_ kind: TagKind) {
        let value = cleaned(drafts[kind])
        drafts[kind] = ""
        guard !value.isEmpty,
              !(tags[kind] ?? []).contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        tags[kind, default: []].append(value)
    }

    func remove(_ kind: TagKind, at offsets: IndexSet) {
        tags[kind]?.remove(atOffsets: offsets)
    }

    func save(server: PlexServer, sectionId: String, client: PlexAPIClient) async -> PlexMetadata? {
        TagKind.allCases.forEach(commitDraft)
        guard hasChanges, !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }

        let changes = TagKind.allCases.compactMap { kind -> (kind: TagKind, added: [String], removed: [String])? in
            let before = original[kind] ?? []
            let after = tags[kind] ?? []
            let added = after.filter { !before.contains($0) }
            let removed = before.filter { !after.contains($0) }
            return added.isEmpty && removed.isEmpty ? nil : (kind, added, removed)
        }

        do {
            try await client.updateTags(server: server, ratingKey: item.ratingKey, changes: changes)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        let fresh = (try? await client.getMetadata(server: server, ratingKey: item.ratingKey)) ?? item
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
        let kind = item.type == "artist" ? LibraryStore.Kind.artist : LibraryStore.Kind.album
        await LibraryStore.shared.upsert(page: [fresh], kind: kind, scope: scope)
        await LibraryStore.shared.saveDetail(fresh, serverId: server.machineIdentifier)
        await LibraryStore.shared.invalidateMemory(kind: kind, scope: scope)
        Notification.Name.postLibraryContentDidChange()
        return fresh
    }

    private func cleaned(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
