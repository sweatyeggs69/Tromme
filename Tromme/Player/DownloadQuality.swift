import Foundation

enum DownloadQuality: String, CaseIterable {
    case original
    case spaceSaver

    static let storageKey = "downloadQuality"

    var displayName: String {
        switch self {
        case .original: "Original"
        case .spaceSaver: "Space Saver"
        }
    }

    static var current: DownloadQuality {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? DownloadQuality.original.rawValue
        return DownloadQuality(rawValue: raw) ?? .original
    }

    /// Codecs worth converting: lossless sources (large) and Opus (poor AVPlayer support).
    /// Every other lossy codec downloads as the original file.
    private static let transcodedCodecs: Set<String> = [
        "flac", "alac", "wav", "aiff", "ape", "wavpack", "wv", "tta", "dts", "truehd", "opus"
    ]

    static func transcodes(codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return transcodedCodecs.contains(codec) || codec.hasPrefix("pcm")
    }
}
