import Foundation
import SwiftData

@Model
final class LibraryRecord {
    #Index<LibraryRecord>([\.scope, \.kind], [\.parentRatingKey], [\.grandparentRatingKey], [\.scope, \.kind, \.lastViewedAt], [\.scope, \.kind, \.userRating])

    @Attribute(.unique) var id: String
    var scope: String
    var kind: Int
    var ratingKey: String
    var parentRatingKey: String?
    var grandparentRatingKey: String?
    var updatedAt: Int?
    var lastViewedAt: Int?
    var userRating: Double?
    var payload: Data
    var digest: Data
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
