import SwiftUI

/// One concert: calendar tile, city, then venue, weekday and time. Opens the ticket page.
struct ArtistConcertRowView: View {
    @Environment(\.openURL) private var openURL

    let concert: ConcertEvent

    var body: some View {
        Button {
            if let url = concert.url { openURL(url) }
        } label: {
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text(concert.monthText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                    Text(concert.dayText)
                        .font(.title.weight(.medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(concert.location)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(concert.detailText)
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
        .disabled(concert.url == nil)
    }
}

#Preview {
    ArtistConcertRowView(
        concert: ConcertEvent(
            id: "preview",
            city: "Mesa",
            region: "AZ",
            venue: "Mesa Amphitheatre",
            date: Date(),
            hasTime: true,
            url: nil
        )
    )
    .padding()
    .background(Color(red: 0.08, green: 0.16, blue: 0.22))
    .environment(\.colorScheme, .dark)
}
