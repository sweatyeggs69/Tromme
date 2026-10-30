import Foundation

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
        guard PlusStore.cachedIsPlus else { return .original }
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? DownloadQuality.original.rawValue
        if raw == "spaceSaver" { return .kbps256 }
        return DownloadQuality(rawValue: raw) ?? .original
    }

    func transcodeBitrate(codec: String?, sourceBitrate: Int?) -> Int? {
        guard let cap = maxBitrateKbps else { return nil }
        if let sourceBitrate {
            return sourceBitrate > cap ? cap : nil
        }
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
