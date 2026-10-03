import Foundation
import SwiftData

/// One row of the on-disk library mirror: an artist (kind 8), album (9) or track (10).
/// The full `PlexMetadata` is stored as JSON in `payload` so views keep working with the
/// model they already use; the other columns exist only so the store can answer
/// "children of X" / "tracks by artist Y" with an indexed query instead of a network call.
@Model
final class LibraryRecord {
    #Index<LibraryRecord>([\.scope, \.kind], [\.parentRatingKey], [\.grandparentRatingKey], [\.scope, \.kind, \.lastViewedAt], [\.scope, \.kind, \.userRating])

    /// "\(serverId)|\(ratingKey)" — rating keys are unique per server.
    @Attribute(.unique) var id: String
    /// "\(serverId)|\(sectionId)"
    var scope: String
    var kind: Int
    var ratingKey: String
    var parentRatingKey: String?
    var grandparentRatingKey: String?
    var updatedAt: Int?
    /// Per-user state mirrored from the payload so Home (recently played, favorites) is an
    /// indexed local query rather than a server request.
    var lastViewedAt: Int?
    var userRating: Double?
    /// JSON-encoded `PlexMetadata` from the library listing.
    var payload: Data
    /// SHA-256 of `payload`, so a sync can skip rows that didn't change without decoding.
    var digest: Data
    /// JSON-encoded `PlexMetadata` from `/library/metadata/{id}` (adds fields the listing
    /// omits, e.g. an artist's `similar` tags). Valid while `detailUpdatedAt == updatedAt`.
    var detail: Data?
    var detailUpdatedAt: Int?

    init(
        id: String, scope: String, kind: Int, ratingKey: String,
        parentRatingKey: String?, grandparentRatingKey: String?,
        updatedAt: Int?, lastViewedAt: Int?, userRating: Double?, payload: Data, digest: Data
    ) {
        self.id = id
        self.scope = scope
        self.kind = kind
        self.ratingKey = ratingKey
        self.parentRatingKey = parentRatingKey
        self.grandparentRatingKey = grandparentRatingKey
        self.updatedAt = updatedAt
        self.lastViewedAt = lastViewedAt
        self.userRating = userRating
        self.payload = payload
        self.digest = digest
    }
}
