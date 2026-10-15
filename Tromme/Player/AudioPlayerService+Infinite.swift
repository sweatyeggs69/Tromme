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

            let poolArtistKeySet = Set(similar.map(\.ratingKey)).union([seedArtistKey])
            let poolAlbumKeys = Set(allAlbums.compactMap { album -> String? in
                guard let parentKey = album.parentRatingKey,
                      poolArtistKeySet.contains(parentKey) else { return nil }
                return album.ratingKey
            })

            let matchedPool = allTracks.filter {
                poolAlbumKeys.contains($0.parentRatingKey ?? "") && $0.ratingKey != seedTrackKey
            }

            guard !Task.isCancelled, !matchedPool.isEmpty else {
                await MainActor.run { self.logPlayback("magic_mix_build_empty", "") }
                return
            }

            var dispersed = Self.evenlyDispersedShuffle(matchedPool)

            // The seed artist is part of the pool for dispersion purposes, but the mix
            // should open with a different artist than the one already playing.
            if let first = dispersed.first,
               (first.grandparentRatingKey ?? first.parentRatingKey ?? first.ratingKey) == seedArtistKey,
               let swapIndex = dispersed.firstIndex(where: {
                   ($0.grandparentRatingKey ?? $0.parentRatingKey ?? $0.ratingKey) != seedArtistKey
               }) {
                dispersed.swapAt(0, swapIndex)
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
              let seed = albums.first(where: { $0.ratingKey == albumKey }) else { return fallback }
        let seedGenres = genres(of: seed)
        let seedStyles = tagSet(seed.style)
        guard !seedGenres.isEmpty else { return fallback }

        let sameGenreAlbums = albums.filter { !genres(of: $0).isDisjoint(with: seedGenres) }
        let freshByAlbum = Dictionary(grouping: fresh, by: { $0.parentRatingKey ?? "" })

        func tracksOf(_ albums: [PlexMetadata]) -> [PlexMetadata] {
            albums.flatMap { freshByAlbum[$0.ratingKey] ?? [] }
        }

        // Same genre plus the required shared styles, relaxed to what the seed actually has
        // (a seed with one style can only share one). Never drops the genre requirement.
        let requiredStyles = min(infiniteMinSharedStyles, seedStyles.count)
        if requiredStyles > 0 {
            let styled = tracksOf(sameGenreAlbums.filter {
                tagSet($0.style).intersection(seedStyles).count >= requiredStyles
            })
            if !styled.isEmpty { return styled }
        }
        let sameGenre = tracksOf(sameGenreAlbums)
        return sameGenre.isEmpty ? fallback : sameGenre
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

            // Genre/style tags live on albums in Plex, not tracks.
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
                return Array(pool.shuffled().prefix(currentNeeded))
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
