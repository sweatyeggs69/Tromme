import Foundation
import Observation

/// Form state and save logic for `EditMetadataSheet` (tracks and albums).
@Observable @MainActor
final class EditMetadataViewModel {
    let item: PlexMetadata
    let isTrack: Bool

    var title: String
    var artist: String
    var album: String
    var yearText: String
    var trackNumberText: String
    private(set) var isSaving = false
    var errorMessage: String?

    init(item: PlexMetadata) {
        self.item = item
        isTrack = item.type == "track"
        title = item.title
        artist = (isTrack ? item.grandparentTitle : item.parentTitle) ?? ""
        album = item.parentTitle ?? ""
        yearText = item.year.map(String.init) ?? ""
        trackNumberText = item.index.map(String.init) ?? ""
    }

    private var originalArtist: String { (isTrack ? item.grandparentTitle : item.parentTitle) ?? "" }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedArtist: String { artist.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAlbum: String { album.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var titleChanged: Bool { trimmedTitle != item.title }
    private var artistChanged: Bool { trimmedArtist != originalArtist }
    private var albumChanged: Bool { isTrack && trimmedAlbum != (item.parentTitle ?? "") }
    private var yearChanged: Bool { yearText.trimmingCharacters(in: .whitespaces) != (item.year.map(String.init) ?? "") }
    private var trackNumberChanged: Bool {
        isTrack && trackNumberText.trimmingCharacters(in: .whitespaces) != (item.index.map(String.init) ?? "")
    }

    /// Artist or album changed on a track, or the artist of an album: items get re-parented.
    private var reparents: Bool { isTrack ? (artistChanged || albumChanged) : artistChanged }

    var hasChanges: Bool { titleChanged || artistChanged || albumChanged || yearChanged || trackNumberChanged }

    var isValid: Bool {
        guard !trimmedTitle.isEmpty, !trimmedArtist.isEmpty else { return false }
        if isTrack, trimmedAlbum.isEmpty { return false }
        if !yearText.isEmpty, Int(yearText.trimmingCharacters(in: .whitespaces)) == nil { return false }
        if !trackNumberText.isEmpty, Int(trackNumberText.trimmingCharacters(in: .whitespaces)) == nil { return false }
        return true
    }

    /// Writes the changes, then re-reads the item and updates the local library so lists
    /// show the new values. Returns the fresh item, or nil when the save failed.
    func save(server: PlexServer, sectionId: String, client: PlexAPIClient) async -> PlexMetadata? {
        guard hasChanges, isValid, !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }

        var fields: [(name: String, value: String)] = []
        if titleChanged {
            fields.append(("title.value", trimmedTitle))
            fields.append(("title.locked", "1"))
        }
        if yearChanged {
            fields.append(("year.value", yearText.trimmingCharacters(in: .whitespaces)))
            fields.append(("year.locked", "1"))
        }
        if trackNumberChanged {
            fields.append(("index.value", trackNumberText.trimmingCharacters(in: .whitespaces)))
            fields.append(("index.locked", "1"))
        }
        if reparents {
            // Tracks need both artist and album named to be re-parented.
            fields.append(("artist.title.value", trimmedArtist))
            if isTrack { fields.append(("album.title.value", trimmedAlbum)) }
        }

        do {
            try await client.updateLibraryItem(
                server: server,
                sectionId: sectionId,
                type: isTrack ? 10 : 9,
                ratingKey: item.ratingKey,
                fields: fields
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        let fresh = (try? await client.getMetadata(server: server, ratingKey: item.ratingKey)) ?? item
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
        let kind = isTrack ? LibraryStore.Kind.track : LibraryStore.Kind.album
        await LibraryStore.shared.upsert(page: [fresh], kind: kind, scope: scope)
        await LibraryStore.shared.saveDetail(fresh, serverId: server.machineIdentifier)
        await LibraryStore.shared.invalidateMemory(kind: kind, scope: scope)
        NotificationCenter.default.post(name: .libraryContentDidChange, object: nil)

        // Titles are copied into child and sibling rows (a track carries its album and artist
        // names), so renames and moves need the mirror re-read.
        if !isTrack || reparents {
            Task { await client.smartRefresh(server: server, sectionId: sectionId, forceLibrarySync: true) }
        }
        return fresh
    }
}
