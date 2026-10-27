import SwiftUI

/// One concert: calendar tile, city, then venue, weekday and time. Opens the ticket page.
struct ArtistConcertRowView: View {
    let concert: ConcertEvent
    var includesDate = false
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ConcertDateTileView(concert: concert, size: 64)

                VStack(alignment: .leading, spacing: 2) {
                    Text(concert.location)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(concert.detailText(includesDate: includesDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ArtistConcertRowView(
        concert: ConcertEvent(
            id: "preview",
            city: "Mesa",
            region: "AZ",
            venue: "Mesa Amphitheatre",
            address: "263 N Center St",
            date: Date(),
            instant: nil,
            hasTime: true,
            url: nil
        ),
        onSelect: {}
    )
    .padding()
    .background(Color(red: 0.08, green: 0.16, blue: 0.22))
    .environment(\.colorScheme, .dark)
}
