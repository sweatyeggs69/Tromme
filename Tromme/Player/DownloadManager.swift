import Foundation
import Observation

enum AutoDownloadMode: String, CaseIterable {
    case library
    case queue

    static let defaultMode: AutoDownloadMode = .queue

    var displayName: String {
        switch self {
        case .library: "Entire Library"
        case .queue: "Dynamic"
        }
    }
}

// MP3 is the only conversion PMS supports over the progressive http transcode
// path — AAC (ADTS) and MP4 targets pass the decision but stream zero bytes.
enum DownloadFormat: String, CaseIterable {
    case original
    case mp3

    static let defaultFormat: DownloadFormat = .mp3

    var displayName: String {
        switch self {
        case .original: "Original (Best Quality)"
        case .mp3: "MP3 (Space Saver)"
        }
    }

    /// Plex container name for the converted download; doubles as the file
    /// extension. `nil` means download the source file untouched.
    var container: String? {
        switch self {
        case .original: nil
        case .mp3: "mp3"
        }
    }
}

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

    static let downloadFormatKey = "downloadFormat"
    static let downloadTranscodeBitrateKbps = 320

    private var preferredDownloadFormat: DownloadFormat {
        UserDefaults.standard.string(forKey: Self.downloadFormatKey)
            .flatMap(DownloadFormat.init(rawValue:)) ?? .defaultFormat
    }

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
        verifyExistingDownloads()
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

        // Server-side conversion when a lossy download format is selected;
        // falls back to the original file if the transcode fails.
        if let targetContainer = preferredDownloadFormat.container {
            let converted = await downloadConverted(
                track: resolvedTrack,
                container: targetContainer,
                server: server,
                client: client
            )
            if converted || Task.isCancelled { return }
        }

        let container = resolvedTrack.media?.first?.container
            ?? resolvedTrack.media?.first?.part?.first?.container
            ?? "mp3"

        do {
            try await fetchAndStore(
                request: URLRequest(url: downloadURL),
                filename: "\(ratingKey).\(container)",
                track: resolvedTrack,
                server: server,
                client: client
            )
        } catch {
            if Task.isCancelled {
                transientStates.removeValue(forKey: ratingKey)
            } else {
                transientStates[ratingKey] = .failed
            }
        }
    }

    /// Downloads the track converted to `container` (AAC/MP3) via the PMS
    /// universal transcoder. Returns false when the server refuses or the
    /// transfer fails, so the caller can fall back to the original file.
    private func downloadConverted(
        track: PlexMetadata,
        container: String,
        server: PlexServer,
        client: PlexAPIClient
    ) async -> Bool {
        let ratingKey = track.ratingKey
        let bitrate = Self.downloadTranscodeBitrateKbps
        let metadataPath = track.key ?? "/library/metadata/\(ratingKey)"
        let normalizedPath = metadataPath.hasPrefix("/") ? metadataPath : "/\(metadataPath)"
        let sessionID = UUID().uuidString
        let headers = client.downloadTranscodeHeaders(
            server: server,
            sessionID: sessionID,
            container: container,
            codec: container
        )
        guard let url = client.transcodeDownloadURL(
            server: server,
            metadataPath: normalizedPath,
            sessionID: sessionID,
            fileExtension: container,
            bitrateKbps: bitrate
        ) else { return false }

        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        defer {
            Task { await client.universalTranscodeStop(server: server, sessionID: sessionID) }
        }
        do {
            try await client.universalDecision(
                server: server,
                metadataPath: normalizedPath,
                sessionID: sessionID,
                headers: headers,
                streamProtocol: "http",
                allowDirectStream: false,
                constrainAudioBitrate: true,
                cellularTranscodeBitrate: bitrate
            )
            try await fetchAndStore(
                request: request,
                filename: "\(ratingKey).\(container)",
                track: track,
                server: server,
                client: client
            )
            return true
        } catch {
            #if DEBUG
            print("[DownloadManager] Converted download failed for \(ratingKey) (\(container)): \(error)")
            #endif
            if Task.isCancelled {
                transientStates.removeValue(forKey: ratingKey)
            }
            return false
        }
    }

    private func fetchAndStore(
        request: URLRequest,
        filename: String,
        track: PlexMetadata,
        server: PlexServer,
        client: PlexAPIClient
    ) async throws {
        let ratingKey = track.ratingKey
        let destURL = downloadsDirectory.appendingPathComponent(filename)

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let statusCode = (response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
            throw PlexAPIError.serverError(statusCode)
        }
        // A dying transcoder can return 200 with an empty body — don't record
        // an empty file as a successful download.
        let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path))?[.size] as? Int64 ?? 0
        guard downloadedSize > 0 else {
            throw PlexAPIError.serverError(-1)
        }
        try Task.checkCancellation()

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path))?[.size] as? Int64 ?? 0
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
            durationMs: track.duration
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
