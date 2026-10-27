import SwiftUI

struct ArtistConcertsListView: View {
    let concerts: [ConcertEvent]
    let onSelect: (ConcertEvent) -> Void

    var body: some View {
        List(concerts) { concert in
            ArtistConcertRowView(concert: concert) { onSelect(concert) }
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle("Upcoming Concerts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ArtistConcertsListView(concerts: [
            ConcertEvent(id: "1", city: "Mesa", region: "AZ", venue: "Mesa Amphitheatre",
            address: "263 N Center St", date: Date(), instant: nil, hasTime: true, url: nil),
            ConcertEvent(id: "2", city: "Denver", region: "CO", venue: "Red Rocks", address: nil, date: Date().addingTimeInterval(86_400 * 9), instant: nil, hasTime: false, url: nil)
        ], onSelect: { _ in })
    }
}
