import Foundation

extension PlexAPIClient {
    func updateLibraryItem(
        server: PlexServer,
        sectionId: String,
        type: Int,
        ratingKey: String,
        fields: [(name: String, value: String)]
    ) async throws {
        var parts = ["type=\(type)", "id=\(ratingKey)"]
        parts += fields.map { "\($0.name)=\(Self.encodeQueryValue($0.value))" }
        do {
            _ = try await rawServerRequest(
                server: server,
                path: "/library/sections/\(sectionId)/all?\(parts.joined(separator: "&"))",
                method: "PUT"
            )
        } catch PlexAPIError.serverError(400) {
            let plain = fields.filter { $0.name.hasSuffix(".value") && !$0.name.hasPrefix("artist.") && !$0.name.hasPrefix("album.") }
            guard !plain.isEmpty, plain.count == fields.filter({ $0.name.hasSuffix(".value") }).count else {
                throw PlexAPIError.serverError(400)
            }
            let query = plain.map { "\($0.name.dropLast(".value".count))=\(Self.encodeQueryValue($0.value))" }
            _ = try await rawServerRequest(
                server: server,
                path: "/library/metadata/\(ratingKey)?\(query.joined(separator: "&"))",
                method: "PUT"
            )
        }
    }

    private static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}
