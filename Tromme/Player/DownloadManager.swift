import Foundation
import Observation

struct DownloadedTrackRecord: Codable, Identifiable, Sendable {
    let ratingKey: String
    let title: String
    let artistName: String
    let albumName: String
    let albumRatingKey: String?
    let artistRatingKey: String?
    let thumbPath: String?
    let relativeFilePath: String
    let downloadedAt: Date
    let fileSize: Int64
    let durationMs: Int?

    var id: String { ratingKey }

    func asPlexMetadata() -> PlexMetadata {
        PlexMetadata(
            ratingKey: ratingKey,
            title: title,
            grandparentTitle: artistName,
            parentTitle: albumName,
            parentRatingKey: albumRatingKey,
            thumbPath: thumbPath,
            durationMs: durationMs
        )
    }
}

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
        loadPersistedRecords()
        verifyExistingDownloads()
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
            try? FileManager.default.removeItem(at: url)
            records.removeValue(forKey: ratingKey)
            persistRecords()
        }
    }

    func cancelAllPendingDownloads() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        pendingQueue.removeAll()
        activeDownloadCount = 0
        transientStates.removeAll()
        userStoppedAutoDownload = true
    }

    func resumeAutoDownload(tracks: [PlexMetadata], server: PlexServer, client: PlexAPIClient) {
        userStoppedAutoDownload = false
        downloadBatch(tracks: tracks, server: server, client: client)
    }

    func deleteAllDownloads() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        pendingQueue.removeAll()
        activeDownloadCount = 0
        try? FileManager.default.removeItem(at: downloadsDirectory)
        records.removeAll()
        transientStates.removeAll()
        persistRecords()
    }

    // MARK: - Private

    private var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrommeDownloads", isDirectory: true)
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

        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let container = resolvedTrack.media?.first?.container
            ?? resolvedTrack.media?.first?.part?.first?.container
            ?? "mp3"
        let filename = "\(ratingKey).\(container)"
        let destURL = downloadsDirectory.appendingPathComponent(filename)

        do {
            let (tempURL, _) = try await URLSession.shared.download(for: URLRequest(url: downloadURL))

            guard !Task.isCancelled else {
                transientStates.removeValue(forKey: ratingKey)
                return
            }

            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path))?[.size] as? Int64 ?? 0
            let thumbPath = resolvedTrack.thumb ?? resolvedTrack.parentThumb
            let record = DownloadedTrackRecord(
                ratingKey: ratingKey,
                title: resolvedTrack.title,
                artistName: resolvedTrack.artistName,
                albumName: resolvedTrack.albumName,
                albumRatingKey: resolvedTrack.parentRatingKey,
                artistRatingKey: resolvedTrack.grandparentRatingKey,
                thumbPath: thumbPath,
                relativeFilePath: filename,
                downloadedAt: Date(),
                fileSize: fileSize,
                durationMs: resolvedTrack.duration
            )
            records[ratingKey] = record
            transientStates.removeValue(forKey: ratingKey)
            persistRecords()

            // Prefetch artwork at all three bucket sizes so it's available offline
            // in track rows (256), grids (512), and Now Playing / album headers (896).
            if let thumbPath {
                await withTaskGroup(of: Void.self) { group in
                    for px in [256, 512, 896] {
                        if let url = client.artworkURL(server: server, path: thumbPath, width: px, height: px) {
                            group.addTask {
                                _ = await ImageCache.shared.image(for: url, targetPixelSize: px)
                            }
                        }
                    }
                }
            }

        } catch {
            if Task.isCancelled {
                transientStates.removeValue(forKey: ratingKey)
            } else {
                transientStates[ratingKey] = .failed
            }
        }
    }

    // MARK: - Persistence

    private func persistRecords() {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func loadPersistedRecords() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let loaded = try? JSONDecoder().decode([DownloadedTrackRecord].self, from: data) else { return }
        for record in loaded {
            records[record.ratingKey] = record
        }
    }

    private func verifyExistingDownloads() {
        let invalidKeys = records.keys.filter { key in
            guard let record = records[key] else { return true }
            return !FileManager.default.fileExists(
                atPath: downloadsDirectory.appendingPathComponent(record.relativeFilePath).path
            )
        }
        if !invalidKeys.isEmpty {
            invalidKeys.forEach { records.removeValue(forKey: $0) }
            persistRecords()
        }
    }
}
