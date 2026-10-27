import SwiftUI

struct ArtistConcertsListView: View {
    let artist: PlexMetadata
    let concerts: [ConcertEvent]
    let backdropColor: Color
    let onShuffle: () -> Void

    @State private var selectedConcert: ConcertEvent?

    var body: some View {
        List {
            HStack(spacing: 20) {
                ArtworkView(thumbPath: artist.thumb, size: 107, cornerRadius: 53.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upcoming Concerts")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(artist.title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
            .listRowSeparator(.hidden)

            Text("All Upcoming Concerts")
                .font(.title3.bold())
                .listRowSeparator(.hidden)

            ForEach(concerts) { concert in
                ArtistConcertRowView(
                    concert: concert,
                    includesDate: true,
                    showsDivider: concert.id != concerts.last?.id
                ) { selectedConcert = concert }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedConcert) { concert in
            ArtistConcertDetailView(concert: concert, artist: artist, backdropColor: backdropColor, onShuffle: onShuffle)
        }
    }
}

#Preview {
    NavigationStack {
        ArtistConcertsListView(artist: PlexMetadata(ratingKey: "1", title: "The Band CAMINO"), concerts: [
            ConcertEvent(id: "1", city: "Mesa", region: "AZ", venue: "Mesa Amphitheatre",
            address: "263 N Center St", date: Date(), instant: nil, hasTime: true, url: nil),
            ConcertEvent(id: "2", city: "Denver", region: "CO", venue: "Red Rocks", address: nil, date: Date().addingTimeInterval(86_400 * 9), instant: nil, hasTime: false, url: nil)
        ], backdropColor: .brown, onShuffle: {})
    }
}
