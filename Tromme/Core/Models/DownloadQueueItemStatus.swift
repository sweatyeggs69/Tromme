import Foundation

/// Status of an item in the Plex `/downloadQueue` (Download Queue API).
enum DownloadQueueItemStatus: String, Decodable, Sendable {
    case deciding, waiting, processing, available, error, expired
}
