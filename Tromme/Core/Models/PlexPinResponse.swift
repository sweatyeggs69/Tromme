import Foundation

struct PlexPinResponse: Decodable, Sendable {
    let id: Int
    let code: String
    let authToken: String?

    enum CodingKeys: String, CodingKey {
        case id, code
        case authToken
        case authTokenSnake = "auth_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
            ?? container.decodeIfPresent(String.self, forKey: .authTokenSnake)
    }
}
