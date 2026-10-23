import AVFoundation
import MediaPlayer
import Network
import Observation

// Magic Mix and Infinite Mode queue refill.
extension AudioPlayerService {
    func requestMagicMixRefill(freshMix: Bool = false) {
        if freshMix {
            magicMixBuildTask?.cancel()
            magicMixBuildTask = nil
            magicMixSeedArtistKey = nil
        }
        guard magicMixBuildTask == nil else { return }
        guard let server, let client else { return }
        guard let sectionId = AppContext.shared.serverConnection.currentLibrarySectionId else { return }
        guard let currentTrack else { return }

        if magicMixSeedArtistKey == nil {
            magicMixSeedArtistKey = currentTrack.grandparentRatingKey
        }
        guard let seedArtistKey = magicMixSeedArtistKey else { return }
        let seedTrackKey = currentTrack.ratingKey

        logPlayback("magic_mix_build_begin", "seed=\(seedArtistKey)")

        magicMixBuildTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.magicMixBuildTask = nil
                }
            }
            guard let self else { return }

            let similar = (try? await client.similarArtists(
                server: server, sectionId: sectionId, seedArtistKey: seedArtistKey
            )) ?? []

            guard !Task.isCancelled else { return }

            async let allAlbumsTask = client.cachedAlbums(server: server, sectionId: sectionId)
            async let allTracksTask = client.cachedTracks(server: server, sectionId: sectionId)
            let allAlbums = (try? await allAlbumsTask) ?? []
            let allTracks = (try? await allTracksTask) ?? []

            let similarKeySet = Set(similar.map(\.ratingKey))
            let albumArtist = Dictionary(
                allAlbums.compactMap { album in album.parentRatingKey.map { (album.ratingKey, $0) } },
                uniquingKeysWith: { first, _ in first }
            )

            var similarTracks: [PlexMetadata] = []
            var seedTracks: [PlexMetadata] = []
            for track in allTracks where track.ratingKey != seedTrackKey {
                guard let artistKey = albumArtist[track.parentRatingKey ?? ""] else { continue }
                if artistKey == seedArtistKey {
                    seedTracks.append(track)
                } else if similarKeySet.contains(artistKey) {
                    similarTracks.append(track)
                }
            }

            // Seed artist contributes up to the user-set multiple (default 2x) of the similar tracks, spread across its albums.
            // With no similar tracks at all, fall back to the whole seed catalog.
            let seedMultiplier = max(1, UserDefaults.standard.object(forKey: "magicMixSeedCap") as? Int ?? 2)
            let seedLimit = similarTracks.isEmpty ? seedTracks.count : similarTracks.count * seedMultiplier
            let pickedSeed = Self.evenlySpreadAcrossAlbums(seedTracks, limit: seedLimit)

            guard !Task.isCancelled, !(similarTracks.isEmpty && pickedSeed.isEmpty) else {
                await MainActor.run { self.logPlayback("magic_mix_build_empty", "") }
                return
            }

            let infinite = await MainActor.run { self.isInfiniteModeActive }
            var dispersed: [PlexMetadata]
            if infinite {
                // Infinite Mode: similar artists first, seed artist tracks after.
                dispersed = Self.evenlyDispersedShuffle(similarTracks) + Self.evenlyDispersedShuffle(pickedSeed)
            } else {
                dispersed = Self.evenlyDispersedShuffle(similarTracks + pickedSeed)
                // The mix should open with a different artist than the one already playing.
                if let first = dispersed.first,
                   (first.grandparentRatingKey ?? first.parentRatingKey ?? first.ratingKey) == seedArtistKey,
                   let swapIndex = dispersed.firstIndex(where: {
                       ($0.grandparentRatingKey ?? $0.parentRatingKey ?? $0.ratingKey) != seedArtistKey
                   }) {
                    dispersed.swapAt(0, swapIndex)
                }
            }

            await MainActor.run {
                for track in dispersed {
                    self.addToEndOfQueue(track)
                }
                self.logPlayback("magic_mix_build_complete", "added=\(dispersed.count)")
            }
        }

        // Clear the queue down to the current track now that magicMixBuildTask is
        // already non-nil — this closes the window where Infinite Mode's queue
        // didSet could otherwise race in a random track before the mix lands.
        if freshMix {
            clearQueue()
        }
    }

    /// Picks up to `limit` tracks round-robin across albums so each album contributes equally.
    static func evenlySpreadAcrossAlbums(_ tracks: [PlexMetadata], limit: Int) -> [PlexMetadata] {
        guard limit > 0 else { return [] }
        var groups = Dictionary(grouping: tracks, by: { $0.parentRatingKey ?? "" })
            .values.map { $0.shuffled() }.shuffled()
        var result: [PlexMetadata] = []
        while result.count < limit, !groups.isEmpty {
            for i in groups.indices.reversed() {
                guard result.count < limit else { break }
                result.append(groups[i].removeFirst())
                if groups[i].isEmpty { groups.remove(at: i) }
            }
        }
        return result
    }

    // Spreads tracks evenly by artist across the entire queue using weighted fair queuing.
    // Each artist accumulates budget at a rate proportional to their share of the pool —
    // the artist with the most accumulated budget is always picked next. This guarantees
    // artists with fewer tracks are still spread throughout rather than front-loaded.
    static func evenlyDispersedShuffle(_ tracks: [PlexMetadata]) -> [PlexMetadata] {
        var byArtist: [String: [PlexMetadata]] = [:]
        for track in tracks {
            let key = track.grandparentRatingKey ?? track.parentRatingKey ?? track.ratingKey
            byArtist[key, default: []].append(track)
        }

        let total = tracks.count
        guard total > 0 else { return [] }

        struct ArtistQueue {
            var tracks: [PlexMetadata]
            var budget: Double
            let rate: Double
        }

        var queues = byArtist.values.map { group -> ArtistQueue in
            let shuffled = group.shuffled()
            let rate = Double(shuffled.count) / Double(total)
            // Random phase offset so priority order varies between mixes
            return ArtistQueue(tracks: shuffled, budget: rate * Double.random(in: 0..<1), rate: rate)
        }

        var result: [PlexMetadata] = []
        result.reserveCapacity(total)

        while !queues.isEmpty {
            for i in queues.indices { queues[i].budget += queues[i].rate }
            let idx = queues.indices.max(by: { queues[$0].budget < queues[$1].budget })!
            result.append(queues[idx].tracks.removeFirst())
            queues[idx].budget -= 1.0
            if queues[idx].tracks.isEmpty { queues.remove(at: idx) }
        }

        return result
    }

    func requestInfiniteRefill() {
        infiniteRefillTask?.cancel()
        infiniteRefillTask = nil
        maybeRefillInfiniteQueueIfNeeded(trigger: "user_request")
    }

    /// Returns true if the current track's artist has at least one other album in the library.
    func magicMixAvailable() async -> Bool {
        guard let client, let server,
              let sectionId = AppContext.shared.serverConnection.currentLibrarySectionId,
              let artistKey = currentTrack?.grandparentRatingKey,
              let currentAlbumKey = currentTrack?.parentRatingKey else { return false }
        let allAlbums = (try? await client.cachedAlbums(server: server, sectionId: sectionId)) ?? []
        return allAlbums.contains { $0.parentRatingKey == artistKey && $0.ratingKey != currentAlbumKey }
    }

    func trimPlayedHistoryIfNeeded() {
        guard isInfiniteModeActive else { return }
        let dropCount = currentIndex - infiniteModeHistoryLimit
        guard dropCount > 0, dropCount < queue.count else { return }
        queue.removeFirst(dropCount)
        currentIndex -= dropCount
    }

    func infiniteCandidates(from tracks: [PlexMetadata], albums: [PlexMetadata], artists: [PlexMetadata]) -> [PlexMetadata] {
        let queuedKeys = Set(queue.map(\.ratingKey))
        let fresh = tracks.filter { !queuedKeys.contains($0.ratingKey) }
        let fallback = fresh.isEmpty ? tracks : fresh

        func tagSet(_ tags: [PlexTag]?) -> Set<String> {
            Set((tags ?? []).compactMap { $0.tag?.lowercased() })
        }

        let artistGenres = Dictionary(artists.map { ($0.ratingKey, tagSet($0.genre)) }, uniquingKeysWith: { first, _ in first })

        /// Album genres, falling back to the album artist's genres when the album has none.
        func genres(of album: PlexMetadata) -> Set<String> {
            let own = tagSet(album.genre)
            guard own.isEmpty, let artistKey = album.parentRatingKey else { return own }
            return artistGenres[artistKey] ?? []
        }

        guard let albumKey = currentTrack?.parentRatingKey,
              let seed = albums.first(where: { $0.ratingKey == albumKey }) else { return fallback.shuffled() }
        let seedStyles = tagSet(seed.style)
        let seedMoods = tagSet(seed.mood)

        let freshByAlbum = Dictionary(grouping: fresh, by: { $0.parentRatingKey ?? "" })

        /// Shared style and mood counts per album, used to rank its tracks.
        func score(of album: PlexMetadata) -> (styles: Int, moods: Int) {
            (tagSet(album.style).intersection(seedStyles).count,
             tagSet(album.mood).intersection(seedMoods).count)
        }

        /// Random order weighted by score (Efraimidis-Spirakis), so more matches come up
        /// more often without always repeating the same top tracks.
        func weightedShuffle(_ scored: [(track: PlexMetadata, weight: Int)]) -> [PlexMetadata] {
            scored
                .map { (track: $0.track, key: pow(Double.random(in: .ulpOfOne..<1), 1 / Double(max($0.weight, 1)))) }
                .sorted { $0.key > $1.key }
                .map(\.track)
        }

        func tracks(of albums: [PlexMetadata], minStyles: Int, minMoods: Int) -> [PlexMetadata] {
            var scored: [(track: PlexMetadata, weight: Int)] = []
            for album in albums {
                let s = score(of: album)
                if s.styles < minStyles { continue }
                if s.moods < minMoods { continue }
                for track in freshByAlbum[album.ratingKey] ?? [] {
                    scored.append((track, s.styles + s.moods))
                }
            }
            return weightedShuffle(scored)
        }

        // At least infiniteMinSharedStyles shared styles and infiniteMinSharedMoods shared
        // moods, capped at what the seed has, then relaxed to styles only. Albums without
        // enough tags to qualify, and seeds with no styles or moods, fall back to a shared
        // genre. Only when that finds nothing does it use the whole library.
        let needStyles = min(infiniteMinSharedStyles, seedStyles.count)
        let needMoods = min(infiniteMinSharedMoods, seedMoods.count)
        var attempts: [(Int, Int)] = []
        if needStyles > 0 || needMoods > 0 { attempts.append((needStyles, needMoods)) }
        if needStyles > 0, needMoods > 0 { attempts.append((needStyles, 0)) }
        for (styles, moods) in attempts {
            let matched = tracks(of: albums, minStyles: styles, minMoods: moods)
            if !matched.isEmpty { return matched }
        }

        let seedGenres = genres(of: seed)
        if !seedGenres.isEmpty {
            let sameGenre = tracks(
                of: albums.filter { !genres(of: $0).isDisjoint(with: seedGenres) },
                minStyles: 0, minMoods: 0
            )
            if !sameGenre.isEmpty { return sameGenre }
        }
        return fallback.shuffled()
    }

    func maybeRefillInfiniteQueueIfNeeded(trigger: String) {
        guard isInfiniteModeActive else { return }
        // Defer to Magic Mix while it's active so a random infinite-mode track
        // can't sneak into the queue ahead of the mix it's about to build.
        guard !isMagicMixActive else { return }
        let needed = 1 - upcomingTracks.count
        guard needed > 0 else { return }
        guard infiniteRefillTask == nil else { return }
        guard let server, let client else { return }
        guard let sectionId = AppContext.shared.serverConnection.currentLibrarySectionId else { return }

        logPlayback("infinite_refill_begin", "trigger=\(trigger) needed=\(needed)")

        infiniteRefillTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.infiniteRefillTask = nil
                }
            }

            guard let self else { return }
            let allTracks = (try? await client.cachedTracks(server: server, sectionId: sectionId)) ?? []

            guard !Task.isCancelled else { return }
            guard !allTracks.isEmpty else {
                await MainActor.run {
                    self.logPlayback("infinite_refill_empty", "trigger=\(trigger)")
                }
                return
            }

            // Style/mood tags live on albums in Plex, not tracks.
            // The listing omits Style, so read the stored detail payloads.
            var allAlbums = await LibraryStore.shared.albumsPreferringDetail(
                scope: LibraryScope.id(serverId: server.machineIdentifier, sectionId: sectionId)
            )
            // Make sure the seed album's tags are current even if enrichment hasn't reached it.
            let seedAlbumKey = await MainActor.run { self.currentTrack?.parentRatingKey }
            if let seedAlbumKey,
               let detail = try? await client.cachedMetadata(server: server, ratingKey: seedAlbumKey),
               let index = allAlbums.firstIndex(where: { $0.ratingKey == seedAlbumKey }) {
                allAlbums[index] = detail
            }
            let allArtists = (try? await client.cachedArtists(server: server, sectionId: sectionId)) ?? []
            guard !Task.isCancelled else { return }

            let selected: [PlexMetadata] = await MainActor.run {
                let currentNeeded = 1 - self.upcomingTracks.count
                guard currentNeeded > 0 else { return [] }
                let pool = self.infiniteCandidates(from: allTracks, albums: allAlbums, artists: allArtists)
                return Array(pool.prefix(currentNeeded))
            }

            guard !selected.isEmpty else { return }

            await MainActor.run {
                for track in selected {
                    self.addToEndOfQueue(track)
                }
                self.logPlayback("infinite_refill_complete", "added=\(selected.count) upcoming=\(self.upcomingTracks.count)")
            }
        }
    }
}
