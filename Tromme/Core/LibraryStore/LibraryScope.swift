import Foundation

/// Identifies one server + library section in the local store.
enum LibraryScope {
    static func id(serverId: String, sectionId: String) -> String {
        "\(serverId)|\(sectionId)"
    }
    static func recordID(serverId: String, ratingKey: String) -> String {
        "\(serverId)|\(ratingKey)"
    }
    static func serverId(of scope: String) -> String {
        String(scope.split(separator: "|", maxSplits: 1).first ?? "")
    }
}
