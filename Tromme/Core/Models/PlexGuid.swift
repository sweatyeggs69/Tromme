import Foundation

/// An external agent id on a metadata item (`Guid` in the spec), e.g. `mbid://<uuid>`.
struct PlexGuid: Codable, Sendable, Hashable {
    let id: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? c.decodeIfPresent(String.self, forKey: .id) {
            id = string
        } else if let number = try? c.decodeIfPresent(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = nil
        }
    }
}
