import Foundation
import SwiftData
import CryptoKit

/// The on-disk mirror of the user's Plex music library (SwiftData, in Application Support
/// so the OS never purges it). Browsing reads from here; the network is only touched by
/// `LibrarySyncService`, which keeps this mirror up to date in the background.
@ModelActor
actor LibraryStore {
    /// A ModelActor made on the main thread ends up running its database work on the main
    /// thread, which freezes the UI during a sync — so always build it off the main thread.
    static let shared: LibraryStore = {
        let container = makeContainer()
        if Thread.isMainThread {
            return DispatchQueue.global(qos: .userInitiated).sync { LibraryStore(modelContainer: container) }
        }
        return LibraryStore(modelContainer: container)
    }()

    /// Synchronous access to the artist/album lists for instant first paint.
    nonisolated static let memory = LibraryMemory()

    enum Kind {
        static let artist = 8
        static let album = 9
        static let track = 10
    }

    /// Single-slot cache of the full track list (AllSongs, search, compilation credits).
    private var allTracksCache: (scope: String, tracks: [PlexMetadata])?

    // MARK: - Container

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([
            LibraryRecord.self, LibrarySyncRecord.self,
            PlaylistRecord.self, PlaylistItemsRecord.self, ServerRecord.self,
        ])
        let fm = FileManager.default
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrommeLibraryStore", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // The mirror is rebuildable from the server — keep it out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)

        let url = dir.appendingPathComponent("Library.store")
        func make() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        }
        do {
            return try make()
        } catch {
            // Unreadable / incompatible store: it's only a mirror, so rebuild from scratch.
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            do { return try make() } catch {
                fatalError("Unable to create library store: \(error)")
            }
        }
    }

    // MARK: - Sync state

    struct SyncState: Sendable {
        var metaReady = false
        var tracksReady = false
        var serverUpdatedAt = 0
        var lastSyncedAt = Date.distantPast
    }

    func syncState(scope: String) -> SyncState {
        guard let record = syncRecord(scope: scope) else { return SyncState() }
        return SyncState(
            metaReady: record.metaReady,
            tracksReady: record.tracksReady,
            serverUpdatedAt: record.serverUpdatedAt,
            lastSyncedAt: record.lastSyncedAt
        )
    }

    func isReady(kind: Int, scope: String) -> Bool {
        let state = syncState(scope: scope)
        return kind == Kind.track ? state.tracksReady : state.metaReady
    }

    func markReady(kind: Int, scope: String) {
        let record = syncRecord(scope: scope) ?? insertSyncRecord(scope: scope)
        if kind == Kind.track { record.tracksReady = true } else { record.metaReady = true }
        try? modelContext.save()
    }

    func markSynced(scope: String, serverUpdatedAt: Int) {
        let record = syncRecord(scope: scope) ?? insertSyncRecord(scope: scope)
        record.serverUpdatedAt = serverUpdatedAt
        record.lastSyncedAt = Date()
        try? modelContext.save()
    }

    private func syncRecord(scope: String) -> LibrarySyncRecord? {
        var descriptor = FetchDescriptor<LibrarySyncRecord>(predicate: #Predicate { $0.scope == scope })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func insertSyncRecord(scope: String) -> LibrarySyncRecord {
        let record = LibrarySyncRecord(scope: scope)
        modelContext.insert(record)
        return record
    }

    // MARK: - Reads

    /// All items of a kind. Artists/albums are served from the in-memory copy once loaded.
    func items(kind: Int, scope: String) -> [PlexMetadata] {
        if kind == Kind.track {
            if let cached = allTracksCache, cached.scope == scope { return cached.tracks }
        } else if let cached = Self.memory.items(scope: scope, kind: kind) {
            return cached
        }
        let descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.scope == scope && $0.kind == kind }
        )
        let decoded = decodeAll((try? modelContext.fetch(descriptor)) ?? [])
        if kind == Kind.track {
            allTracksCache = (scope, decoded)
        } else {
            Self.memory.set(decoded, scope: scope, kind: kind)
        }
        return decoded
    }

    /// Albums of an artist, or tracks of an album — an indexed lookup on the parent key.
    func children(of parentKey: String, scope: String) -> [PlexMetadata] {
        let descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.parentRatingKey == parentKey && $0.scope == scope }
        )
        let items = decodeAll((try? modelContext.fetch(descriptor)) ?? [])
        if items.first?.type == "track" {
            return items.sorted {
                ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0)
            }
        }
        return items.sorted { ($0.titleSort ?? $0.title) < ($1.titleSort ?? $1.title) }
    }

    /// Every track whose grandparent is `artistKey`.
    func tracks(byArtist artistKey: String, scope: String) -> [PlexMetadata] {
        let track = Kind.track
        let descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate {
                $0.grandparentRatingKey == artistKey && $0.kind == track && $0.scope == scope
            }
        )
        return decodeAll((try? modelContext.fetch(descriptor)) ?? [])
    }

    /// The library section an item was mirrored from, if the store has it.
    func sectionId(ofRatingKey ratingKey: String, serverId: String) -> String? {
        record(ratingKey: ratingKey, serverId: serverId)
            .flatMap { $0.scope.split(separator: "|", maxSplits: 1).last.map(String.init) }
    }

    /// The listing payload for one item.
    func item(ratingKey: String, serverId: String) -> PlexMetadata? {
        record(ratingKey: ratingKey, serverId: serverId).flatMap { decode($0.payload) }
    }

    /// The detail payload if it is current for the listing's `updatedAt`.
    func freshDetail(ratingKey: String, serverId: String) -> PlexMetadata? {
        guard let record = record(ratingKey: ratingKey, serverId: serverId),
              let detail = record.detail,
              record.detailUpdatedAt == record.updatedAt else { return nil }
        return decode(detail)
    }

    /// Whatever detail or listing payload exists, however old — for offline fallback.
    func anyMetadata(ratingKey: String, serverId: String) -> PlexMetadata? {
        guard let record = record(ratingKey: ratingKey, serverId: serverId) else { return nil }
        return decode(record.detail ?? record.payload)
    }

    /// Distinct track-level artwork paths that differ from the track's album art. Read in
    /// pages so the full track list is never decoded at once.
    func trackThumbPaths(scope: String) -> Set<String> {
        let kind = Kind.track
        let pageSize = 2000
        var offset = 0
        var paths = Set<String>()
        let decoder = JSONDecoder()
        while true {
            var descriptor = FetchDescriptor<LibraryRecord>(
                predicate: #Predicate { $0.scope == scope && $0.kind == kind }
            )
            descriptor.fetchLimit = pageSize
            descriptor.fetchOffset = offset
            guard let rows = try? modelContext.fetch(descriptor), !rows.isEmpty else { break }
            for row in rows {
                if let track = try? decoder.decode(PlexMetadata.self, from: row.payload),
                   let thumb = track.thumb, thumb != track.parentThumb {
                    paths.insert(thumb)
                }
            }
            offset += pageSize
        }
        return paths
    }

    /// Items of `kind` whose detail payload is missing or out of date.
    func keysNeedingDetail(kind: Int, scope: String) -> [String] {
        let descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.scope == scope && $0.kind == kind }
        )
        return ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { $0.detail == nil || $0.detailUpdatedAt != $0.updatedAt }
            .map(\.ratingKey)
    }

    /// Albums with their detail payload where one exists. The listing omits `Style` tags,
    /// so anything tag-based must read these instead of `items(kind:scope:)`.
    func albumsPreferringDetail(scope: String) -> [PlexMetadata] {
        let kind = Kind.album
        let descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.scope == scope && $0.kind == kind }
        )
        let decoder = JSONDecoder()
        return ((try? modelContext.fetch(descriptor)) ?? []).compactMap {
            try? decoder.decode(PlexMetadata.self, from: $0.detail ?? $0.payload)
        }
    }

    /// Marks every artist/album detail as stale so the next enrichment pass refetches it
    /// (tag edits on the server don't always change the item's `updatedAt`).
    func invalidateDetails(scope: String) {
        let artist = Kind.artist, album = Kind.album
        let descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.scope == scope && ($0.kind == artist || $0.kind == album) }
        )
        for row in (try? modelContext.fetch(descriptor)) ?? [] { row.detailUpdatedAt = nil }
        try? modelContext.save()
    }

    // MARK: - Writes

    func saveDetail(_ metadata: PlexMetadata, serverId: String) {
        guard let record = record(ratingKey: metadata.ratingKey, serverId: serverId),
              let data = encode(metadata) else { return }
        record.detail = data
        record.detailUpdatedAt = record.updatedAt
        try? modelContext.save()
    }

    /// Rewrites one existing row from fresh server metadata (e.g. after an artwork change)
    /// without a full sync.
    func replaceListing(_ metadata: PlexMetadata, serverId: String) {
        guard let row = record(ratingKey: metadata.ratingKey, serverId: serverId),
              let data = encode(metadata) else { return }
        row.payload = data
        row.digest = Data(SHA256.hash(data: data))
        row.updatedAt = metadata.updatedAt
        row.lastViewedAt = metadata.lastViewedAt
        row.userRating = metadata.userRating
        row.detail = data
        row.detailUpdatedAt = metadata.updatedAt
        try? modelContext.save()
        invalidateMemory(kind: row.kind, scope: row.scope)
    }

    /// Inserts new rows and rewrites changed ones (by payload digest). Returns the page's
    /// record ids so the caller can prune whatever the server no longer has.
    @discardableResult
    func upsert(page: [PlexMetadata], kind: Int, scope: String) -> [String] {
        let serverId = LibraryScope.serverId(of: scope)
        let ids = page.map { LibraryScope.recordID(serverId: serverId, ratingKey: $0.ratingKey) }
        let existing = Dictionary(
            ((try? modelContext.fetch(FetchDescriptor<LibraryRecord>(predicate: #Predicate { ids.contains($0.id) }))) ?? [])
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (item, id) in zip(page, ids) {
            guard let data = encode(item) else { continue }
            let digest = Data(SHA256.hash(data: data))
            if let row = existing[id] {
                // Columns are compared too so rows written before they existed get backfilled.
                guard row.digest != digest || row.scope != scope
                        || row.lastViewedAt != item.lastViewedAt || row.userRating != item.userRating else { continue }
                row.scope = scope
                row.kind = kind
                row.parentRatingKey = item.parentRatingKey
                row.grandparentRatingKey = item.grandparentRatingKey
                row.updatedAt = item.updatedAt
                row.lastViewedAt = item.lastViewedAt
                row.userRating = item.userRating
                row.payload = data
                row.digest = digest
            } else {
                modelContext.insert(LibraryRecord(
                    id: id, scope: scope, kind: kind, ratingKey: item.ratingKey,
                    parentRatingKey: item.parentRatingKey,
                    grandparentRatingKey: item.grandparentRatingKey,
                    updatedAt: item.updatedAt, lastViewedAt: item.lastViewedAt,
                    userRating: item.userRating, payload: data, digest: digest
                ))
            }
        }
        try? modelContext.save()
        return ids
    }

    /// Deletes rows of `kind` in `scope` that are not in `keeping` (removed on the server).
    func prune(kind: Int, scope: String, keeping: Set<String>) {
        var descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.scope == scope && $0.kind == kind }
        )
        descriptor.propertiesToFetch = [\.id]
        for row in (try? modelContext.fetch(descriptor)) ?? [] where !keeping.contains(row.id) {
            modelContext.delete(row)
        }
        try? modelContext.save()
    }

    /// Call once a kind's rows have changed so readers rebuild their in-memory copies.
    func invalidateMemory(kind: Int, scope: String) {
        if kind == Kind.track {
            allTracksCache = nil
        } else {
            Self.memory.remove(scope: scope, kind: kind)
        }
    }

    func remove(ratingKey: String, serverId: String) {
        guard let row = record(ratingKey: ratingKey, serverId: serverId) else { return }
        let (scope, kind) = (row.scope, row.kind)
        modelContext.delete(row)
        try? modelContext.save()
        invalidateMemory(kind: kind, scope: scope)
    }

    /// Frees the large in-memory track list (memory warning).
    func clearMemory() {
        allTracksCache = nil
    }

    func deleteAll() {
        try? modelContext.delete(model: LibraryRecord.self)
        try? modelContext.delete(model: LibrarySyncRecord.self)
        try? modelContext.delete(model: PlaylistRecord.self)
        try? modelContext.delete(model: PlaylistItemsRecord.self)
        try? modelContext.delete(model: ServerRecord.self)
        try? modelContext.save()
        allTracksCache = nil
        Self.memory.removeAll()
    }

    // MARK: - Home (local queries)

    /// Newest albums by `addedAt`.
    func recentlyAdded(scope: String, limit: Int) -> [PlexMetadata] {
        Array(items(kind: Kind.album, scope: scope).sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(limit))
    }

    /// Most recently played tracks.
    func recentlyPlayed(scope: String, limit: Int) -> [PlexMetadata] {
        let kind = Kind.track
        var descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.scope == scope && $0.kind == kind && $0.lastViewedAt != nil },
            sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return decodeAll((try? modelContext.fetch(descriptor)) ?? [])
    }

    /// Tracks rated at least `minUserRating` (same threshold the server-side query used).
    func favorites(scope: String, minUserRating: Double) -> [PlexMetadata] {
        decodeAll(favoriteRows(scope: scope, minUserRating: minUserRating))
    }

    func favoriteKeys(scope: String, minUserRating: Double) -> Set<String> {
        Set(favoriteRows(scope: scope, minUserRating: minUserRating).map(\.ratingKey))
    }

    private func favoriteRows(scope: String, minUserRating: Double) -> [LibraryRecord] {
        let kind = Kind.track
        let descriptor = FetchDescriptor<LibraryRecord>(
            predicate: #Predicate { $0.scope == scope && $0.kind == kind && ($0.userRating ?? 0) >= minUserRating }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Writes fresh per-user state (play counts, ratings) for already-mirrored tracks and
    /// patches the in-memory track list in place, so it isn't re-decoded from disk.
    func applyTrackUpdates(_ tracks: [PlexMetadata], scope: String) {
        guard !tracks.isEmpty else { return }
        upsert(page: tracks, kind: Kind.track, scope: scope)
        if var cached = allTracksCache, cached.scope == scope {
            let updates = Dictionary(tracks.map { ($0.ratingKey, $0) }, uniquingKeysWith: { _, last in last })
            for index in cached.tracks.indices {
                if let updated = updates[cached.tracks[index].ratingKey] { cached.tracks[index] = updated }
            }
            allTracksCache = cached
        }
    }

    /// Saves artist/album detail payloads in one transaction.
    func saveDetails(_ items: [PlexMetadata], serverId: String) {
        for metadata in items {
            guard let record = record(ratingKey: metadata.ratingKey, serverId: serverId),
                  let data = encode(metadata) else { continue }
            record.detail = data
            record.detailUpdatedAt = record.updatedAt
        }
        try? modelContext.save()
    }

    // MARK: - Playlists

    func playlists(serverId: String) -> [PlexPlaylist] {
        let descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.serverId == serverId },
            sortBy: [SortDescriptor(\.position)]
        )
        let decoder = JSONDecoder()
        return ((try? modelContext.fetch(descriptor)) ?? []).compactMap { try? decoder.decode(PlexPlaylist.self, from: $0.payload) }
    }

    func playlistsSynced(serverId: String) -> Bool {
        serverRecord(serverId: serverId)?.playlistsSyncedAt != nil
    }

    /// Replaces the playlist listing with the server's, dropping playlists (and their
    /// items) that no longer exist.
    func savePlaylists(_ playlists: [PlexPlaylist], serverId: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let existing = Dictionary(
            ((try? modelContext.fetch(FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.serverId == serverId }))) ?? [])
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var keep = Set<String>()
        for (position, playlist) in playlists.enumerated() {
            guard let data = try? encoder.encode(playlist) else { continue }
            let id = LibraryScope.recordID(serverId: serverId, ratingKey: playlist.ratingKey)
            keep.insert(id)
            if let row = existing[id] {
                row.position = position
                row.payload = data
                row.updatedAt = playlist.updatedAt
                row.leafCount = playlist.leafCount
            } else {
                modelContext.insert(PlaylistRecord(
                    id: id, serverId: serverId, ratingKey: playlist.ratingKey, position: position,
                    payload: data, updatedAt: playlist.updatedAt, leafCount: playlist.leafCount
                ))
            }
        }
        for (id, row) in existing where !keep.contains(id) {
            modelContext.delete(row)
            if let items = itemsRecord(id: id) { modelContext.delete(items) }
        }
        (serverRecord(serverId: serverId) ?? insertServerRecord(serverId: serverId)).playlistsSyncedAt = Date()
        try? modelContext.save()
    }

    func playlistItems(playlistKey: String, serverId: String) -> [PlexMetadata]? {
        guard let row = itemsRecord(id: LibraryScope.recordID(serverId: serverId, ratingKey: playlistKey)) else { return nil }
        return try? JSONDecoder().decode([PlexMetadata].self, from: row.payload)
    }

    /// Playlist keys whose stored items are missing or older than the listing says.
    func playlistKeysNeedingItems(serverId: String) -> [String] {
        let playlistRows = (try? modelContext.fetch(FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.serverId == serverId }))) ?? []
        let itemRows = Dictionary(
            ((try? modelContext.fetch(FetchDescriptor<PlaylistItemsRecord>(predicate: #Predicate { $0.serverId == serverId }))) ?? [])
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return playlistRows.filter { row in
            guard let items = itemRows[row.id] else { return true }
            return items.playlistUpdatedAt != row.updatedAt || items.playlistLeafCount != row.leafCount
        }.map(\.ratingKey)
    }

    func savePlaylistItems(_ items: [PlexMetadata], playlistKey: String, serverId: String) {
        let id = LibraryScope.recordID(serverId: serverId, ratingKey: playlistKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(items) else { return }
        let listing = playlistRecord(id: id)
        if let row = itemsRecord(id: id) {
            row.payload = data
            row.playlistUpdatedAt = listing?.updatedAt
            row.playlistLeafCount = listing?.leafCount
        } else {
            modelContext.insert(PlaylistItemsRecord(
                id: id, serverId: serverId, ratingKey: playlistKey, payload: data,
                playlistUpdatedAt: listing?.updatedAt, playlistLeafCount: listing?.leafCount
            ))
        }
        try? modelContext.save()
    }

    func removePlaylist(playlistKey: String, serverId: String) {
        let id = LibraryScope.recordID(serverId: serverId, ratingKey: playlistKey)
        if let row = playlistRecord(id: id) { modelContext.delete(row) }
        if let row = itemsRecord(id: id) { modelContext.delete(row) }
        try? modelContext.save()
    }

    private func playlistRecord(id: String) -> PlaylistRecord? {
        var descriptor = FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func itemsRecord(id: String) -> PlaylistItemsRecord? {
        var descriptor = FetchDescriptor<PlaylistItemsRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Library sections

    func sections(serverId: String) -> [LibrarySection]? {
        guard let data = serverRecord(serverId: serverId)?.sectionsPayload else { return nil }
        return try? JSONDecoder().decode([LibrarySection].self, from: data)
    }

    func saveSections(_ sections: [LibrarySection], serverId: String) {
        guard let data = try? JSONEncoder().encode(sections) else { return }
        (serverRecord(serverId: serverId) ?? insertServerRecord(serverId: serverId)).sectionsPayload = data
        try? modelContext.save()
    }

    private func serverRecord(serverId: String) -> ServerRecord? {
        var descriptor = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.serverId == serverId })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func insertServerRecord(serverId: String) -> ServerRecord {
        let record = ServerRecord(serverId: serverId)
        modelContext.insert(record)
        return record
    }

    // MARK: - Helpers

    private func record(ratingKey: String, serverId: String) -> LibraryRecord? {
        let id = LibraryScope.recordID(serverId: serverId, ratingKey: ratingKey)
        var descriptor = FetchDescriptor<LibraryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func encode(_ metadata: PlexMetadata) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(metadata)
    }

    private func decode(_ data: Data) -> PlexMetadata? {
        try? JSONDecoder().decode(PlexMetadata.self, from: data)
    }

    private func decodeAll(_ rows: [LibraryRecord]) -> [PlexMetadata] {
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(PlexMetadata.self, from: $0.payload) }
    }
}
