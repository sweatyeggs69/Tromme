import Foundation

/// Mirrors the Plex library into `LibraryStore` in the background.
///
/// A sync runs two overlapping phases — artists + albums, then tracks — each streamed to
/// disk page by page and diffed against what's already stored (changed rows rewritten,
/// vanished rows pruned). Existing data stays readable throughout; nothing is deleted up
/// front, so an interrupted or offline sync never leaves the library empty.
actor LibrarySyncService {
    static let shared = LibrarySyncService()

    /// Re-sync at least this often even if the server's section `updatedAt` hasn't moved.
    private let safetyNetInterval: TimeInterval = 7 * 86_400

    private struct Run {
        let meta: Task<Void, Error>
        let tracks: Task<Void, Error>
    }
    private var runs: [String: Run] = [:]
    private var enrichmentTasks: [String: Task<Void, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var playlistRefreshes: [String: Task<Void, Error>] = [:]

    // MARK: - Public

    /// Syncs if the section changed since the last sync, was never synced, or hasn't been
    /// verified for a week (or `force`). No library traffic beyond one cheap sections call
    /// when nothing changed.
    func refreshIfNeeded(client: PlexAPIClient, server: PlexServer, sectionId: String, force: Bool = false) async {
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
        guard let sections = try? await client.getLibrarySections(server: server),
              let section = sections.first(where: { $0.key == sectionId }) else { return }
        await LibraryStore.shared.saveSections(sections, serverId: server.machineIdentifier)
        let serverUpdatedAt = section.updatedAt ?? 0
        let state = await LibraryStore.shared.syncState(scope: scope)
        let complete = state.metaReady && state.tracksReady
        let stale = Date().timeIntervalSince(state.lastSyncedAt) > safetyNetInterval
            && !NetworkStatus.shared.isExpensive
        guard force || !complete || stale || state.serverUpdatedAt != serverUpdatedAt else {
            // Nothing changed, but a previous prefetch may have been interrupted — resume it.
            schedulePrefetch(client: client, server: server, sectionId: sectionId, includeTracks: true)
            return
        }

        if force { await LibraryStore.shared.invalidateDetails(scope: scope) }
        let run = startRun(client: client, server: server, sectionId: sectionId, scope: scope, serverUpdatedAt: serverUpdatedAt, firstSync: !state.metaReady)
        _ = try? await run.meta.value
        _ = try? await run.tracks.value
    }

    /// Runs `client.performPlaylistRefresh`, sharing one in-flight refresh per server
    /// between concurrent callers (launch sync, Home pull-to-refresh, prefetch).
    func refreshPlaylists(client: PlexAPIClient, server: PlexServer) async throws {
        let serverId = server.machineIdentifier
        if let existing = playlistRefreshes[serverId] {
            return try await existing.value
        }
        let task = Task { try await client.performPlaylistRefresh(server: server) }
        playlistRefreshes[serverId] = task
        defer { playlistRefreshes[serverId] = nil }
        try await task.value
    }

    /// Suspends until `kind` has been mirrored at least once, starting a sync if none is
    /// running. Returns immediately once data exists. Throws if the first sync fails
    /// (e.g. offline before the library was ever loaded).
    func waitUntilReady(kind: Int, client: PlexAPIClient, server: PlexServer, sectionId: String) async throws {
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
        if await LibraryStore.shared.isReady(kind: kind, scope: scope) { return }

        let run: Run
        if let existing = runs[scope] {
            run = existing
        } else {
            let sections = try await client.getLibrarySections(server: server)
            let updatedAt = sections.first(where: { $0.key == sectionId })?.updatedAt ?? 0
            run = startRun(client: client, server: server, sectionId: sectionId, scope: scope, serverUpdatedAt: updatedAt, firstSync: true)
        }
        try await (kind == LibraryStore.Kind.track ? run.tracks : run.meta).value
    }

    // MARK: - Run

    private func startRun(
        client: PlexAPIClient, server: PlexServer, sectionId: String, scope: String, serverUpdatedAt: Int, firstSync: Bool
    ) -> Run {
        if let existing = runs[scope] { return existing }

        // Don't inherit the caller's priority: launch-time refreshes run at .background, which
        // iOS throttles hard. Someone is waiting on a first sync, so run that one promptly.
        let priority: TaskPriority = firstSync ? .userInitiated : .utility
        let meta = Task<Void, Error>(priority: priority) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.mirror(kind: LibraryStore.Kind.artist, client: client, server: server, sectionId: sectionId, scope: scope)
                }
                group.addTask {
                    try await Self.mirror(kind: LibraryStore.Kind.album, client: client, server: server, sectionId: sectionId, scope: scope)
                }
                try await group.waitForAll()
            }
            await LibraryStore.shared.markReady(kind: LibraryStore.Kind.album, scope: scope)
            NotificationCenter.default.post(name: .libraryContentDidChange, object: nil)
        }
        // Tracks download alongside artists/albums but are only committed after them, so
        // the store never holds tracks whose albums it hasn't seen yet.
        let tracks = Task<Void, Error>(priority: priority) {
            try await Self.mirror(kind: LibraryStore.Kind.track, client: client, server: server, sectionId: sectionId, scope: scope) {
                try await meta.value
            }
            await LibraryStore.shared.markReady(kind: LibraryStore.Kind.track, scope: scope)
            await LibraryStore.shared.markSynced(scope: scope, serverUpdatedAt: serverUpdatedAt)
            NotificationCenter.default.post(name: .libraryContentDidChange, object: nil)
        }
        let run = Run(meta: meta, tracks: tracks)
        runs[scope] = run

        Task {
            _ = try? await meta.value
            _ = try? await tracks.value
            self.finishRun(scope: scope, client: client, server: server)
        }
        return run
    }

    private func finishRun(scope: String, client: PlexAPIClient, server: PlexServer) {
        runs[scope] = nil
        guard enrichmentTasks[scope] == nil,
              let sectionId = scope.split(separator: "|", maxSplits: 1).last.map(String.init) else { return }
        // Stages after the library itself: 3) artist details, then 4) artwork — last, so it
        // never competes with the data the UI actually needs.
        enrichmentTasks[scope] = Task(priority: .utility) {
            await Self.enrichDetails(client: client, server: server, scope: scope)
            self.finishEnrichment(scope: scope)
            self.schedulePrefetch(client: client, server: server, sectionId: sectionId, includeTracks: true)
        }
    }

    /// Queues the artwork pass (stage 4). Does nothing while a sync or artist-detail pass
    /// is still running for the library — the last of those starts it when it finishes.
    private func schedulePrefetch(client: PlexAPIClient, server: PlexServer, sectionId: String, includeTracks: Bool) {
        let scope = LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
        guard runs[scope] == nil, enrichmentTasks[scope] == nil else { return }
        let previous = prefetchTask
        prefetchTask = Task(priority: .utility) {
            await previous?.value
            // Playlist covers are part of the artwork pass, so make sure playlists are mirrored first.
            try? await self.refreshPlaylists(client: client, server: server)
            await LibraryPrefetcher.prefetchArtwork(client: client, server: server, sectionId: sectionId, includeTracks: includeTracks)
        }
    }

    private func finishEnrichment(scope: String) {
        enrichmentTasks[scope] = nil
    }

    /// Streams one kind from the server into the store and prunes rows the server dropped.
    private static func mirror(
        kind: Int, client: PlexAPIClient, server: PlexServer, sectionId: String, scope: String,
        beforeFirstWrite: (@Sendable () async throws -> Void)? = nil
    ) async throws {
        var seen = Set<String>()
        var gate = beforeFirstWrite
        #if DEBUG
        let started = ContinuousClock.now
        print("[LibrarySync] kind \(kind): started")
        #endif
        do {
            try await client.streamLibraryContents(server: server, sectionId: sectionId, type: kind) { page in
                if let pending = gate {
                    try await pending()
                    gate = nil
                }
                seen.formUnion(await LibraryStore.shared.upsert(page: page, kind: kind, scope: scope))
                #if DEBUG
                print("[LibrarySync] kind \(kind): \(seen.count) items written (\(ContinuousClock.now - started))")
                #endif
            }
            if let pending = gate { try await pending() }
        } catch {
            #if DEBUG
            print("[LibrarySync] kind \(kind): FAILED after \(seen.count) items — \(error)")
            #endif
            throw error
        }
        await LibraryStore.shared.prune(kind: kind, scope: scope, keeping: seen)
        await LibraryStore.shared.invalidateMemory(kind: kind, scope: scope)
        #if DEBUG
        print("[LibrarySync] kind \(kind): done, \(seen.count) items in \(ContinuousClock.now - started)")
        #endif
    }

    /// Fetches `/library/metadata/{id}` for every artist and album so bio, similar artists,
    /// album style tags, etc. are on disk before they're needed. Bounded and low-priority;
    /// skipped on metered networks / Low Power Mode (pages fall back to fetching on demand).
    private static func enrichDetails(client: PlexAPIClient, server: PlexServer, scope: String) async {
        guard !NetworkStatus.shared.isExpensive, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let keys = await LibraryStore.shared.keysNeedingDetail(kind: LibraryStore.Kind.artist, scope: scope)
            + LibraryStore.shared.keysNeedingDetail(kind: LibraryStore.Kind.album, scope: scope)
        guard !keys.isEmpty else { return }
        let serverId = server.machineIdentifier

        // `/library/metadata/{ids}` takes a comma-separated list, so 50 artists cost one
        // request instead of 50 — a 3,000-artist library is ~60 requests, not 3,000.
        let batchSize = 50
        let batches = stride(from: 0, to: keys.count, by: batchSize).map { Array(keys[$0..<min($0 + batchSize, keys.count)]) }
        await withTaskGroup(of: Void.self) { group in
            var iterator = batches.makeIterator()
            func addNext() {
                guard let batch = iterator.next() else { return }
                group.addTask {
                    guard !Task.isCancelled,
                          let details = try? await client.getMetadata(server: server, ratingKeys: batch) else { return }
                    await LibraryStore.shared.saveDetails(details, serverId: serverId)
                }
            }
            for _ in 0..<2 { addNext() }
            while await group.next() != nil { addNext() }
        }
    }
}
