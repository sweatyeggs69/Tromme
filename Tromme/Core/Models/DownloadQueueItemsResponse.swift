import Foundation

struct DownloadQueueItemsResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let status: DownloadQueueItemStatus
        }
        let items: [Item]?
        enum CodingKeys: String, CodingKey { case items = "DownloadQueueItem" }
    }
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}
