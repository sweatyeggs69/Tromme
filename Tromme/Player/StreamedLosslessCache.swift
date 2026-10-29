import Foundation

/// Holds the original FLAC files of streamed tracks while they play, since
/// AVAudioPlayer needs a complete file. Only the current and next track are kept.
@MainActor
final class StreamedLosslessCache {
    static let shared = StreamedLosslessCache()

    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StreamedLossless", isDirectory: true)
    private var tasks: [String: Task<URL, Error>] = [:]

    private init() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Downloads the file once; concurrent callers for the same track share the download.
    func file(for ratingKey: String, from url: URL, keeping others: [String] = []) async throws -> URL {
        prune(keeping: [ratingKey] + others)
        let destination = folder.appendingPathComponent("\(ratingKey).flac")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let task = tasks[ratingKey] { return try await task.value }

        let folder = folder
        let task = Task<URL, Error> {
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            return destination
        }
        tasks[ratingKey] = task
        defer { tasks[ratingKey] = nil }
        return try await task.value
    }

    private func prune(keeping keys: [String]) {
        let keep = Set(keys.map { "\($0).flac" })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in files where !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        for key in tasks.keys where !keys.contains(key) {
            tasks[key]?.cancel()
            tasks[key] = nil
        }
    }
}
