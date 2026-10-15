import Foundation

struct DownloadQueueResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        struct Entry: Decodable, Sendable { let id: Int }
        let downloadQueue: [Entry]?
        enum CodingKeys: String, CodingKey { case downloadQueue = "DownloadQueue" }
    }
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}
