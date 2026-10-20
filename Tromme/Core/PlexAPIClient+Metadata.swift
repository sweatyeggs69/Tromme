import Foundation

// Metadata editing. Endpoint: PUT /library/sections/{sectionId}/all.
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
        _ = try await rawServerRequest(
            server: server,
            path: "/library/sections/\(sectionId)/all?\(parts.joined(separator: "&"))",
            method: "PUT"
        )
    }

    /// Percent-encodes everything but unreserved characters so `&`, `+` and `=` in titles
    /// survive the round trip.
    private static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}
