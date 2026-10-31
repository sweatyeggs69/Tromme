import Foundation

final class DownloadedLyricsStore: Sendable {
    static let shared = DownloadedLyricsStore()

    private let directory: URL

    private init() {
        directory = URL.applicationSupportDirectory
            .appending(path: "TrommeLyrics", directoryHint: .isDirectory)
            .appending(path: "Downloaded", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ ratingKey: String) -> URL {
        directory.appending(path: "\(ratingKey).json")
    }

    func lyrics(forRatingKey ratingKey: String) -> ResolvedLyrics? {
        (try? Data(contentsOf: fileURL(ratingKey)))
            .flatMap { try? JSONDecoder().decode(ResolvedLyrics.self, from: $0) }
    }

    func hasLyrics(forRatingKey ratingKey: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(ratingKey).path)
    }

    func save(_ lyrics: ResolvedLyrics, forRatingKey ratingKey: String) {
        guard let data = try? JSONEncoder().encode(lyrics) else { return }
        try? data.write(to: fileURL(ratingKey), options: .atomic)
    }

    func remove(forRatingKey ratingKey: String) {
        try? FileManager.default.removeItem(at: fileURL(ratingKey))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func prune(keeping ratingKeys: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !ratingKeys.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
