import SwiftUI

/// One concert: artist photo with date badge, ticket and shuffle buttons, date and venue.
struct ArtistConcertDetailView: View {
    @Environment(\.openURL) private var openURL

    let concert: ConcertEvent
    let artist: PlexMetadata
    let backdropColor: Color
    let onShuffle: () -> Void

    @State private var showsCalendarEditor = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ArtworkView(thumbPath: artist.thumb, size: 220, cornerRadius: 110)
                    .overlay(alignment: .bottomTrailing) {
                        ConcertDateTileView(concert: concert, size: 72)
                            .offset(x: 8, y: 8)
                    }
                    .padding(.top, 8)

                Text(artist.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button {
                        if let url = concert.url { openURL(url) }
                    } label: {
                        Label("Get Tickets", systemImage: "ticket")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(concert.url == nil)

                    Button(action: onShuffle) {
                        Label("Artist Station", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                VStack(spacing: 0) {
                    infoRow(title: concert.longDateText, subtitle: concert.timeText, symbol: "calendar.badge.plus") {
                        showsCalendarEditor = true
                    }
                    Divider()
                    infoRow(title: concert.venue, subtitle: concert.addressText, symbol: "mappin.and.ellipse") {
                        if let url = concert.mapURL { openURL(url) }
                    }
                }
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("Powered by Ticketmaster")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
        }
        .background(backdropColor.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showsCalendarEditor) {
            ConcertCalendarEditor(concert: concert, artistName: artist.title)
        }
    }

    private func infoRow(title: String, subtitle: String?, symbol: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: action) {
                Image(systemName: symbol)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    NavigationStack {
        ArtistConcertDetailView(
            concert: ConcertEvent(
                id: "p", city: "Mesa", region: "AZ", venue: "Mesa Amphitheatre", address: "263 N Center St",
                date: Date(), instant: nil, hasTime: true, url: nil
            ),
            artist: PlexMetadata(ratingKey: "1", title: "The Band CAMINO", type: "artist"),
            backdropColor: Color(red: 0.4, green: 0.25, blue: 0.2),
            onShuffle: {}
        )
    }
}
