import SwiftUI

/// One concert: calendar tile, city, then venue, weekday and time. Opens the ticket page.
struct ArtistConcertRowView: View {
    @Environment(\.displayScale) private var displayScale

    let concert: ConcertEvent
    var includesDate = false
    var showsDivider = true
    var dividerColor: Color = Color(.separator)
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ConcertDateTileView(concert: concert, size: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(concert.location)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(concert.detailText(includesDate: includesDate))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        // Drawn here, not by the List, so every divider starts under the text, past the
        // date tile (48) and its spacing (12).
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 1 / displayScale)
                    .padding(.leading, 60)
            }
        }
        .listRowSeparator(.hidden)
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
