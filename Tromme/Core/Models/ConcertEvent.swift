import Foundation

/// An upcoming concert. `date` holds the venue's local wall-clock time read as GMT, so it
/// formats the same everywhere when rendered with a GMT time zone.
struct ConcertEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let city: String
    let region: String?
    let venue: String
    let date: Date
    let hasTime: Bool
    let url: URL?

    var location: String {
        [city, region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var monthText: String { Self.format("MMM", date) }
    var dayText: String { Self.format("d", date) }

    /// "Venue · Fri · 12:00 PM"
    var detailText: String {
        var parts = [venue, Self.format("EEE", date)]
        if hasTime { parts.append(Self.format("h:mm a", date)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate(pattern)
        return formatter.string(from: date)
    }
}
