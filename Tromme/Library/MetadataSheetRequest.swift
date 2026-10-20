import Foundation

/// Which metadata sheet to present for a track or album.
enum MetadataSheetRequest: Identifiable {
    case edit(PlexMetadata)
    case trackInfo(PlexMetadata)

    var id: String {
        switch self {
        case .edit(let item): "edit-\(item.ratingKey)"
        case .trackInfo(let item): "info-\(item.ratingKey)"
        }
    }
}
