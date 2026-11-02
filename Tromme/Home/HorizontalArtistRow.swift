import SwiftUI

struct HorizontalArtistRow: View {
    let artists: [PlexMetadata]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(artists) { artist in
                    NavigationLink(value: artist) {
                        VStack(alignment: .center, spacing: 6) {
                            ArtworkView(
                                thumbPath: artist.thumb,
                                size: 120,
                                cornerRadius: 60
                            )

                            Text(artist.title)
                                .font(AppStyle.Typography.itemTitle)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 120)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, AppStyle.Spacing.pageHorizontal)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

#Preview {
    NavigationStack {
        HorizontalArtistRow(artists: [])
    }
}
