import Foundation

/// Which metadata sheet to present: `.edit` for an album, `.trackInfo` for a track (info and edit in one).
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
