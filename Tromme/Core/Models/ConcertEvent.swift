import Foundation

/// An upcoming concert. `date` holds the venue's local wall-clock time read as GMT, so it
/// formats the same everywhere when rendered with a GMT time zone.
struct ConcertEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let city: String
    let region: String?
    let venue: String
    let address: String?
    let date: Date
    /// The real start instant, when the API gives one; the calendar uses it.
    let instant: Date?
    let hasTime: Bool
    let url: URL?

    var location: String {
        [city, region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// "263 N Center St, Mesa, AZ"
    var addressText: String {
        [address, city, region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var mapURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: [venue, addressText].filter { !$0.isEmpty }.joined(separator: ", "))]
        return components?.url
    }

    /// "January 15, 2027 · Friday"
    var longDateText: String {
        Self.format("MMMMdyyyy", date) + " · " + Self.format("EEEE", date)
    }

    var timeText: String? { hasTime ? Self.format("h:mm a", date) : nil }

    var monthText: String { Self.format("MMM", date) }
    var dayText: String { Self.format("d", date) }

    /// "Venue · Fri · 12 PM", or "Venue · Fri, Jan 15 · 12 PM" with `includesDate`.
    func detailText(includesDate: Bool = false) -> String {
        var parts = [venue, Self.format(includesDate ? "EEEMMMd" : "EEE", date)]
        if hasTime { parts.append(shortTimeText) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "12 PM" on the hour, "7:30 PM" otherwise.
    private var shortTimeText: String {
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return Self.format(gmt.component(.minute, from: date) == 0 ? "j" : "jmm", date)
    }

    private static func format(_ pattern: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate(pattern)
        return formatter.string(from: date)
    }
}
