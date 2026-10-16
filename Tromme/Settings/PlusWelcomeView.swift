import SwiftUI

/// One-time sheet telling Premium Icon Pack owners they have Tromme Plus for free.
struct PlusWelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 10) {
                Text("You Have Tromme Plus")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Thank you so much for purchasing Tromme, it seriously means the world to me. Tromme now has a subscription option to support ongoing development and hosting the animated artwork service. Because you bought the Premium Icon Pack, you have Tromme Plus for free.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                featureRow(symbol: "play.rectangle.on.rectangle.fill", title: "Animated Artwork", detail: "Moving album art on album pages, Now Playing, and the lock screen.")
                featureRow(symbol: "app.badge.fill", title: "Premium Icon Pack", detail: "Every premium app icon, plus new ones as they are added.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Text("Sounds Good")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .interactiveDismissDisabled()
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
    Color.clear.sheet(isPresented: .constant(true)) {
        PlusWelcomeView()
    }
}
