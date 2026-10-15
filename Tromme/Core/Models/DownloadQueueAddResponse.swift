import Foundation

struct DownloadQueueAddResponse: Decodable, Sendable {
    struct Container: Decodable, Sendable {
        struct AddedItem: Decodable, Sendable { let id: Int }
        let addedQueueItems: [AddedItem]?
        enum CodingKeys: String, CodingKey { case addedQueueItems = "AddedQueueItems" }
    }
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}
