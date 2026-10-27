import Foundation

/// Subset of the Ticketmaster Discovery `events.json` payload that Tromme reads.
struct TicketmasterEventsResponse: Decodable, Sendable {
    let embedded: Embedded?

    enum CodingKeys: String, CodingKey { case embedded = "_embedded" }

    struct Embedded: Decodable, Sendable {
        let events: [Event]
    }

    struct Event: Decodable, Sendable {
        let id: String
        let url: URL?
        let dates: Dates?
        let embedded: EventEmbedded?

        enum CodingKeys: String, CodingKey {
            case id, url, dates
            case embedded = "_embedded"
        }
    }

    struct Dates: Decodable, Sendable {
        let start: Start?
    }

    struct Start: Decodable, Sendable {
        let localDate: String?
        let localTime: String?
    }

    struct EventEmbedded: Decodable, Sendable {
        let venues: [Venue]?
        let attractions: [Attraction]?
    }

    struct Venue: Decodable, Sendable {
        let name: String?
        let city: Named?
        let state: State?
        let country: Country?
    }

    struct Named: Decodable, Sendable {
        let name: String?
    }

    struct State: Decodable, Sendable {
        let stateCode: String?
    }

    struct Country: Decodable, Sendable {
        let countryCode: String?
    }

    struct Attraction: Decodable, Sendable {
        let name: String
    }
}
