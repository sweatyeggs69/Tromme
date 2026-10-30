import SwiftUI

struct PlusFeaturesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(symbol: "play.rectangle.on.rectangle.fill", title: "Animated Artwork", detail: "Moving album art on album pages, Now Playing, and the lock screen.")
            featureRow(symbol: "slider.horizontal.below.rectangle", title: "Advanced Playback", detail: "Auto Mix blends songs together, and you can trim the start and end of any track.")
            featureRow(symbol: "arrow.down.circle.fill", title: "Advanced Downloads", detail: "Set a max bitrate to convert downloads and save space.")
            featureRow(symbol: "app.badge.fill", title: "Premium Icon Pack", detail: "Every premium app icon, plus new ones as they are added.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    PlusFeaturesView()
        .padding()
}
