import Foundation

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
