import Foundation

// Metadata editing. Endpoints: PUT /library/sections/{sectionId}/all, falling back to PUT /library/metadata/{ids}.
extension PlexAPIClient {
    /// Sets fields on one track (type 10) or album (type 9). `fields` are the documented
    /// query parameters, e.g. `title.value`, `title.locked`, `artist.title.value`.
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
            // PMS rejects the section form for some items. Plain field edits can go through
            // PUT /library/metadata/{ids}, which takes the bare field names (title, year, index).
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

    /// Percent-encodes everything but unreserved characters so `&`, `+` and `=` in titles
    /// survive the round trip.
    private static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}
