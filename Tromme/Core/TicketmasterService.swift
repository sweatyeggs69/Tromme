import Foundation

struct TicketmasterService: Sendable {

    /// Free key from developer.ticketmaster.com. Concerts stay hidden while this is empty.
    private static let apiKey = ""

    /// Upcoming concerts for `artist`. Results are cached per artist.
    static func fetchConcerts(artist: String) async -> [ConcertEvent] {
        guard !apiKey.isEmpty, !artist.isEmpty else { return [] }

        do {
            return try await ExternalContentCache.shared.cachedFetch(
                [ConcertEvent].self,
                forKey: CacheKey.concerts(artist: artist),
                policy: .concerts
            ) {
                try await fetchEvents(artist: artist)
            }
        } catch {
            return []
        }
    }

    // MARK: - Network

    private static func fetchEvents(artist: String) async throws -> [ConcertEvent] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "app.ticketmaster.com"
        components.path = "/discovery/v2/events.json"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "keyword", value: artist),
            URLQueryItem(name: "classificationName", value: "music"),
            URLQueryItem(name: "sort", value: "date,asc"),
            URLQueryItem(name: "size", value: "50"),
            URLQueryItem(name: "locale", value: "*")
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TicketmasterEventsResponse.self, from: data)
        let wanted = normalized(artist)
        return (decoded.embedded?.events ?? []).compactMap { event in
            // The keyword search also matches tribute acts and festivals, so require the artist
            // itself to be a listed attraction.
            guard event.embedded?.attractions?.contains(where: { normalized($0.name) == wanted }) == true else {
                return nil
            }
            return concert(from: event)
        }
    }

    private static func concert(from event: TicketmasterEventsResponse.Event) -> ConcertEvent? {
        guard let start = event.dates?.start, let localDate = start.localDate else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let hasTime = start.localTime != nil
        formatter.dateFormat = hasTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        let text = hasTime ? "\(localDate) \(start.localTime ?? "")" : localDate
        guard let date = formatter.date(from: text) else { return nil }

        let venue = event.embedded?.venues?.first
        return ConcertEvent(
            id: event.id,
            city: venue?.city?.name ?? "",
            region: venue?.state?.stateCode ?? venue?.country?.countryCode,
            venue: venue?.name ?? "",
            address: venue?.address?.line1,
            date: date,
            instant: start.dateTime,
            hasTime: hasTime,
            url: event.url
        )
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
