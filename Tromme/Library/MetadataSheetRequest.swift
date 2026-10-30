import Foundation

enum MetadataSheetRequest: Identifiable {
    case edit(PlexMetadata)
    case editTags(PlexMetadata)
    case trackInfo(PlexMetadata)

    var id: String {
        switch self {
        case .edit(let item): "edit-\(item.ratingKey)"
        case .editTags(let item): "tags-\(item.ratingKey)"
        case .trackInfo(let item): "info-\(item.ratingKey)"
        }
    }
}
