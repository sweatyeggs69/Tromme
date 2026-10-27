import Foundation
import Observation

@Observable @MainActor
final class DownloadManager: @unchecked Sendable {

    enum TransientState {
        case queued, downloading, failed
    }

    private(set) var transientStates: [String: TransientState] = [:]
    private(set) var records: [String: DownloadedTrackRecord] = [:]

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var pendingQueue: [(PlexMetadata, PlexServer, PlexAPIClient)] = []
    private var activeDownloadCount = 0
    private let maxConcurrentDownloads = 3
    private let persistenceKey = "com.tromme.downloadedRecords.v1"
    /// Set while a debounced `persistRecordsNow()` write is pending — see `persistRecords()`.
    private var persistScheduled = false
    /// False until the on-disk records have been read; writes are skipped before then so an
    /// early persist can't overwrite the file with a partial set.
    private var hasLoadedRecords = false
    private let fileQueue = DispatchQueue(label: "com.tromme.downloadManager.files", qos: .utility)

    var hasActiveDownloads: Bool { !transientStates.isEmpty }

    var pendingDownloadCount: Int {
        transientStates.values.filter { $0 == .queued || $0 == .downloading }.count
    }
    private(set) var userStoppedAutoDownload = false

    var downloadedTracksSorted: [DownloadedTrackRecord] {
        records.values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    var totalStorageUsed: Int64 {
        records.values.reduce(0) { $0 + $1.fileSize }
    }

    var storageDescription: String {
        let count = records.count
        let sizeStr = ByteCountFormatter.string(fromByteCount: totalStorageUsed, countStyle: .file)
        return count == 0 ? "None" : "\(count) song\(count == 1 ? "" : "s") · \(sizeStr)"
    }

    init() {
        Self.migrateLegacyAutoDownloadPreferences()
        loadPersistedRecords()
    }

    /// Maps the retired per-mode toggles ("autoDownloadAllSongs",
    /// "dynamicQueueDownloads") onto the enabled + mode pair.
    private static func migrateLegacyAutoDownloadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoDownloadEnabled") == nil {
            if defaults.bool(forKey: "dynamicQueueDownloads") {
                defaults.set(true, forKey: "autoDownloadEnabled")
                defaults.set(AutoDownloadMode.queue.rawValue, forKey: "autoDownloadMode")
            } else if defaults.bool(forKey: "autoDownloadAllSongs") {
                defaults.set(true, forKey: "autoDownloadEnabled")
                defaults.set(AutoDownloadMode.library.rawValue, forKey: "autoDownloadMode")
            }
        }
        defaults.removeObject(forKey: "autoDownloadAllSongs")
        defaults.removeObject(forKey: "dynamicQueueDownloads")
    }

    // MARK: - Public API

    func isDownloaded(_ ratingKey: String) -> Bool {
        records[ratingKey] != nil
    }

    func localURL(for ratingKey: String) -> URL? {
        guard let record = records[ratingKey] else { return nil }
        let url = downloadsDirectory.appendingPathComponent(record.relativeFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            records.removeValue(forKey: ratingKey)
            persistRecords()
            return nil
        }
        return url
    }

    func download(track: PlexMetadata, server: PlexServer, client: PlexAPIClient) {
        guard !isDownloaded(track.ratingKey) else { return }
        guard transientStates[track.ratingKey] == nil else { return }
        transientStates[track.ratingKey] = .queued
        pendingQueue.append((track, server, client))
        processQueue()
    }

    func downloadBatch(tracks: [PlexMetadata], server: PlexServer, client: PlexAPIClient) {
        for track in tracks { download(track: track, server: server, client: client) }
    }

    func cancelDownload(ratingKey: String) {
        downloadTasks[ratingKey]?.cancel()
        downloadTasks.removeValue(forKey: ratingKey)
        pendingQueue.removeAll { $0.0.ratingKey == ratingKey }
        if transientStates[ratingKey] != nil {
            transientStates.removeValue(forKey: ratingKey)
        }
    }

    func deleteDownload(ratingKey: String) {
        cancelDownload(ratingKey: ratingKey)
        if let record = records[ratingKey] {
            let url = downloadsDirectory.appendingPathComponent(record.relativeFilePath)
            fileQueue.async { try? FileManager.default.removeItem(at: url) }
            records.removeValue(forKey: ratingKey)
            persistRecords()
        }
    }

    func cancelAllPendingDownloads() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        pendingQueue.removeAll()
        // activeDownloadCount is left alone: each cancelled task decrements it itself when it unwinds.
        transientStates.removeAll()
        userStoppedAutoDownload = true
    }

    func resumeAutoDownload(tracks: [PlexMetadata], server: PlexServer, client: PlexAPIClient) {
        userStoppedAutoDownload = false
        downloadBatch(tracks: tracks, server: server, client: client)
    }

    /// Called after a smart-refresh to pick up any tracks added or updated in the library.
    /// Evicts stale downloads when the server's updatedAt is newer than the stored value,
    /// then queues any missing tracks. No-ops if the user stopped auto-download or mode isn't .library.
    func syncLibraryDownloadsIfNeeded(server: PlexServer, sectionId: String, client: PlexAPIClient) async {
        guard !userStoppedAutoDownload else { return }
        let enabled = UserDefaults.standard.bool(forKey: "autoDownloadEnabled")
        let modeRaw = UserDefaults.standard.string(forKey: "autoDownloadMode") ?? AutoDownloadMode.defaultMode.rawValue
        guard enabled, AutoDownloadMode(rawValue: modeRaw) == .library else { return }
        guard let tracks = try? await client.cachedTracks(server: server, sectionId: sectionId) else { return }

        for track in tracks {
            guard let record = records[track.ratingKey],
                  let serverUpdatedAt = track.updatedAt,
                  let storedUpdatedAt = record.sourceUpdatedAt,
                  serverUpdatedAt > storedUpdatedAt else { continue }
            deleteDownload(ratingKey: track.ratingKey)
        }

        downloadBatch(tracks: tracks, server: server, client: client)
    }

    func deleteAllDownloads() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        pendingQueue.removeAll()
        // activeDownloadCount is left alone: each cancelled task decrements it itself when it unwinds.
        let directory = downloadsDirectory
        fileQueue.async { try? FileManager.default.removeItem(at: directory) }
        records.removeAll()
        transientStates.removeAll()
        persistRecords()
    }

    // MARK: - Private

    private var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrommeDownloads", isDirectory: true)
    }

    /// Creates the downloads folder and keeps it out of iCloud / device backups — the
    /// files are re-downloadable and can be many gigabytes.
    private nonisolated static func prepareDownloadsDirectory(_ directory: URL) {
        var dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private func processQueue() {
        while activeDownloadCount < maxConcurrentDownloads, !pendingQueue.isEmpty {
            let (track, server, client) = pendingQueue.removeFirst()
            guard transientStates[track.ratingKey] == .queued else { continue }
            activeDownloadCount += 1
            transientStates[track.ratingKey] = .downloading
            let task = Task { await self.performDownload(track: track, server: server, client: client) }
            downloadTasks[track.ratingKey] = task
        }
    }

    private func performDownload(
        track: PlexMetadata,
        server: PlexServer,
        client: PlexAPIClient
    ) async {
        let ratingKey = track.ratingKey
        defer {
            downloadTasks.removeValue(forKey: ratingKey)
            activeDownloadCount = max(0, activeDownloadCount - 1)
            processQueue()
        }

        // Resolve the part key — fetch full metadata if media info is absent
        let resolvedTrack: PlexMetadata
        if track.media?.first?.part?.first?.key != nil {
            resolvedTrack = track
        } else if let detailed = try? await client.getMetadata(server: server, ratingKey: ratingKey) {
            resolvedTrack = detailed
        } else {
            transientStates[ratingKey] = .failed
            return
        }

        guard let partKey = resolvedTrack.media?.first?.part?.first?.key,
              let downloadURL = client.downloadURL(server: server, partKey: partKey) else {
            transientStates[ratingKey] = .failed
            return
        }

        let directory = downloadsDirectory
        await Task.detached(priority: .utility) { Self.prepareDownloadsDirectory(directory) }.value

        let container = resolvedTrack.media?.first?.container
            ?? resolvedTrack.media?.first?.part?.first?.container
            ?? "mp3"

        let sourceCodec = resolvedTrack.media?.first?.audioCodec
        let transcodeBitrate = DownloadQuality.current.transcodeBitrate(
            codec: sourceCodec,
            sourceBitrate: resolvedTrack.media?.first?.bitrate
        )

        do {
            if let transcodeBitrate {
                do {
                    try await fetchAndStore(
                        filename: "\(ratingKey).\(PlexAPIClient.transcodedFileExtension)",
                        track: resolvedTrack,
                        server: server,
                        client: client,
                        fetch: { try await client.transcodedDownload(server: server, ratingKey: ratingKey, bitrateKbps: transcodeBitrate) }
                    )
                    return
                } catch {
                    // Cancelled downloads stop here; a failed transcode falls back to the original file.
                    if Task.isCancelled { throw error }
                    #if DEBUG
                    print("[Downloads] transcode failed for \(ratingKey): \(error)")
                    #endif
                }
            }
            try await fetchAndStore(
                filename: "\(ratingKey).\(container)",
                track: resolvedTrack,
                server: server,
                client: client,
                fetch: { try await Self.downloadFile(URLRequest(url: downloadURL)) }
            )
        } catch {
            if Task.isCancelled {
                transientStates.removeValue(forKey: ratingKey)
            } else {
                transientStates[ratingKey] = .failed
            }
        }
    }

    private static func downloadFile(_ request: URLRequest) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
            throw PlexAPIError.serverError(statusCode)
        }
        return tempURL
    }

    private func fetchAndStore(
        filename: String,
        track: PlexMetadata,
        server: PlexServer,
        client: PlexAPIClient,
        fetch: () async throws -> URL
    ) async throws {
        let ratingKey = track.ratingKey
        let destURL = downloadsDirectory.appendingPathComponent(filename)

        let tempURL = try await fetch()
        // A dying transcoder can return 200 with an empty body — don't record
        // an empty file as a successful download.
        try Task.checkCancellation()
        let fileSize = try await Task.detached(priority: .utility) {
            try Self.moveDownloadedFile(from: tempURL, to: destURL)
        }.value
        let thumbPath = track.thumb ?? track.parentThumb
        let record = DownloadedTrackRecord(
            ratingKey: ratingKey,
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            albumRatingKey: track.parentRatingKey,
            artistRatingKey: track.grandparentRatingKey,
            thumbPath: thumbPath,
            relativeFilePath: filename,
            downloadedAt: Date(),
            fileSize: fileSize,
            durationMs: track.duration,
            sourceUpdatedAt: track.updatedAt
        )
        records[ratingKey] = record
        transientStates.removeValue(forKey: ratingKey)
        persistRecords()

        // Prefetch artwork once at the largest transcode bucket. The disk cache is
        // keyed without width/height, so this single high-res copy serves track rows,
        // grids, and Now Playing / album headers offline.
        if let thumbPath {
            let px = ArtworkView.maxTranscodePx
            if let url = client.artworkURL(server: server, path: thumbPath, width: px, height: px) {
                _ = await ImageCache.shared.image(for: url, targetPixelSize: px)
            }
        }
    }

    /// Validates and moves a finished download into place; returns its size. Runs off the main actor.
    private nonisolated static func moveDownloadedFile(from tempURL: URL, to destURL: URL) throws -> Int64 {
        let fm = FileManager.default
        let downloadedSize = (try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? Int64 ?? 0
        guard downloadedSize > 0 else {
            throw PlexAPIError.serverError(-1)
        }
        try Task.checkCancellation()

        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try fm.moveItem(at: tempURL, to: destURL)
        return (try? fm.attributesOfItem(atPath: destURL.path))?[.size] as? Int64 ?? 0
    }

    // MARK: - Persistence

    /// Debounces bursts of `persistRecords()` calls (e.g. a library-wide auto-download
    /// completing many tracks back to back) into a single encode+write instead of
    /// re-encoding the entire records dictionary to disk on every completion.
    private func persistRecords() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            persistScheduled = false
            persistRecordsNow()
        }
    }

    /// Call before the app becomes inactive/terminates so no debounced write is lost.
    func flushPendingPersist() {
        persistScheduled = false
        persistRecordsNow()
    }

    /// Structured state lives in a disk file, not UserDefaults (see CLAUDE.md).
    private nonisolated static var recordsFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "TrommeState", directoryHint: .isDirectory)
            .appending(path: "downloadRecords.json")
    }

    /// Encodes on the main actor, then writes on a serial queue so writes stay ordered.
    private func persistRecordsNow() {
        guard hasLoadedRecords,
              let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        let fileURL = Self.recordsFileURL
        fileQueue.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Reads the records file, drops records whose file is gone, and prepares the downloads
    /// folder, all off the main actor so a large library doesn't delay launch.
    private func loadPersistedRecords() {
        let directory = downloadsDirectory
        let legacyKey = persistenceKey
        Task {
            let (loaded, needsPersist) = await Task.detached(priority: .utility) {
                Self.readPersistedRecords(directory: directory, legacyKey: legacyKey)
            }.value
            for record in loaded where records[record.ratingKey] == nil {
                records[record.ratingKey] = record
            }
            hasLoadedRecords = true
            if needsPersist { persistRecordsNow() }
        }
    }

    private nonisolated static func readPersistedRecords(
        directory: URL,
        legacyKey: String
    ) -> (records: [DownloadedTrackRecord], needsPersist: Bool) {
        let fileData = try? Data(contentsOf: recordsFileURL)
        // Older builds kept the records in UserDefaults; move them to the file once.
        let legacyData = fileData == nil ? UserDefaults.standard.data(forKey: legacyKey) : nil
        guard let data = fileData ?? legacyData,
              let loaded = try? JSONDecoder().decode([DownloadedTrackRecord].self, from: data) else {
            return ([], false)
        }
        if legacyData != nil {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        let present = loaded.filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.relativeFilePath).path)
        }
        if !present.isEmpty { prepareDownloadsDirectory(directory) }
        return (present, legacyData != nil || present.count != loaded.count)
    }
}
