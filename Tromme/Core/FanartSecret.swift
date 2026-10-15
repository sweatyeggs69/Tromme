import Foundation

/// The fanart.tv API key, read back from the two Info.plist values `Scripts/make-secrets.sh`
/// writes into the gitignored `Config/Secrets.xcconfig` (key XOR random salt, both hex).
/// This keeps the key out of git and out of a plain `strings` dump of the binary, but it is
/// obfuscation, not encryption: anything the app can read at runtime can be recovered.
enum FanartSecret {
    /// Temporary: paste the fanart.tv key between the quotes to skip the xcconfig setup.
    /// Don't commit it; `git update-index --skip-worktree Tromme/Core/FanartSecret.swift` keeps it local.
    private static let hardcodedKey = ""

    static var apiKey: String? {
        if !hardcodedKey.isEmpty { return hardcodedKey }
        guard let data = bytes(forInfoKey: "FanartKeyData"),
              let salt = bytes(forInfoKey: "FanartKeySalt"),
              !data.isEmpty, data.count == salt.count else { return nil }
        return String(bytes: zip(data, salt).map { $0 ^ $1 }, encoding: .utf8)
    }

    private static func bytes(forInfoKey key: String) -> [UInt8]? {
        guard let hex = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              hex.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
