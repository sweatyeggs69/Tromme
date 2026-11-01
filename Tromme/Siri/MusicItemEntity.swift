import AppIntents

struct MusicItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Music")
    static let defaultQuery = MusicItemQuery()

    let id: String
    let title: String
    let subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }

    var kind: MusicItemKind? {
        id.split(separator: ":", maxSplits: 1).first.flatMap { MusicItemKind(rawValue: String($0)) }
    }

    var ratingKey: String {
        id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
    }

    init(kind: MusicItemKind, ratingKey: String, title: String, subtitle: String?) {
        self.id = "\(kind.rawValue):\(ratingKey)"
        self.title = title
        self.subtitle = subtitle
    }
}
