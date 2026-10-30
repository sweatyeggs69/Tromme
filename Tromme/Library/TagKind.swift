import Foundation

enum TagKind: String, CaseIterable, Hashable {
    case genre
    case style
    case mood

    var title: String {
        switch self {
        case .genre: "Genres"
        case .style: "Styles"
        case .mood: "Moods"
        }
    }

    var addPrompt: String {
        switch self {
        case .genre: "Add Genre"
        case .style: "Add Style"
        case .mood: "Add Mood"
        }
    }

    func tags(in item: PlexMetadata) -> [String] {
        let source: [PlexTag]? = switch self {
        case .genre: item.genre
        case .style: item.style
        case .mood: item.mood
        }
        return (source ?? []).compactMap(\.tag)
    }
}
