import SwiftUI

struct QueueRow: View {
    let track: PlexMetadata

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(
                thumbPath: track.parentThumb ?? track.thumb,
                size: 48,
                cornerRadius: 6
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artistDisplayName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}
