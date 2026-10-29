import Foundation

/// Temporary copies of streamed songs, so their audio can be analysed from disk.
/// AVAssetReader can't reliably read a remote stream, and a local file also makes the
/// seek to the tail instant. Copies are removed once the songs they belong to have played.
enum AutoMixSourceCache {
    private static let maximumBytes: Int64 = 80_000_000

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoMix", isDirectory: true)
    }

    /// Downloads `url` once per `key`. Returns nil when it is too large or the download fails.
    static func localCopy(of url: URL, key: String, fileExtension: String) async -> URL? {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(key).\(fileExtension)")
        if manager.fileExists(atPath: destination.path) { return destination }

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: head),
           response.expectedContentLength > maximumBytes {
            return nil
        }
        guard let (temporary, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? manager.removeItem(at: destination)
        do { try manager.moveItem(at: temporary, to: destination) } catch { return nil }
        return destination
    }

    /// Removes every copy except those for `keys`.
    static func prune(keeping keys: Set<String>) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !keys.contains(file.deletingPathExtension().lastPathComponent) {
            try? manager.removeItem(at: file)
        }
    }
}
