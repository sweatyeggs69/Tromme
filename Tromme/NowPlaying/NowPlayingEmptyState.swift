import SwiftUI

struct NowPlayingEmptyState: View {
    let message: String
    let systemImage: String

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = AppStyle.Artwork.emptyStateIcon

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize))
                .foregroundStyle(.white.opacity(0.3))
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NowPlayingEmptyState(message: "No Lyrics Available", systemImage: "quote.bubble")
        .background(.black)
}
