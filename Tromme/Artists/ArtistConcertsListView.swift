import SwiftUI

struct ArtistConcertsListView: View {
    let concerts: [ConcertEvent]

    var body: some View {
        List(concerts) { concert in
            ArtistConcertRowView(concert: concert)
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
            ConcertEvent(id: "1", city: "Mesa", region: "AZ", venue: "Mesa Amphitheatre", date: Date(), hasTime: true, url: nil),
            ConcertEvent(id: "2", city: "Denver", region: "CO", venue: "Red Rocks", date: Date().addingTimeInterval(86_400 * 9), hasTime: false, url: nil)
        ])
    }
}
