import Foundation

/// Maximum bitrate for downloads. Songs above the cap are converted to AAC on the Plex server.
enum DownloadQuality: String, CaseIterable {
    case original
    case kbps1000 = "1000"
    case kbps320 = "320"
    case kbps256 = "256"
    case kbps192 = "192"
    case kbps128 = "128"

    static let storageKey = "downloadQuality"

    var displayName: String {
        switch self {
        case .original: "Original"
        case .kbps1000: "1 Mbps"
        default: "\(rawValue) kbps"
        }
    }

    var maxBitrateKbps: Int? { Int(rawValue) }

    static var current: DownloadQuality {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? DownloadQuality.original.rawValue
        // "spaceSaver" was the earlier fixed 256 kbps setting.
        if raw == "spaceSaver" { return .kbps256 }
        return DownloadQuality(rawValue: raw) ?? .original
    }

    /// Opus has poor AVPlayer support, so it is always converted.
    private static let alwaysConvertedCodecs: Set<String> = ["opus"]

    /// The AAC bitrate to convert a song to, or nil when it downloads as the original file.
    func transcodeBitrate(codec: String?, sourceBitrate: Int?) -> Int? {
        guard let cap = maxBitrateKbps else { return nil }
        if let codec = codec?.lowercased(), Self.alwaysConvertedCodecs.contains(codec) {
            return max(128, min(cap, sourceBitrate ?? cap))
        }
        if let sourceBitrate {
            return sourceBitrate > cap ? cap : nil
        }
        // Unknown bitrate: only lossless sources are worth converting.
        return Self.isLossless(codec: codec) ? cap : nil
    }

    private static let losslessCodecs: Set<String> = [
        "flac", "alac", "wav", "aiff", "ape", "wavpack", "wv", "tta", "dts", "truehd"
    ]

    private static func isLossless(codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return losslessCodecs.contains(codec) || codec.hasPrefix("pcm")
    }
}
