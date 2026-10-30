import SwiftUI

struct PlusWelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 10) {
                Text("You Have Tromme +")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Thank you so much for purchasing Tromme, it seriously means the world to me. Tromme now has a subscription option to support ongoing development and hosting the animated artwork service. Because you bought the Premium Icon Pack, you have Tromme + for free.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            PlusFeaturesView()

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button {
                    showPaywall = true
                } label: {
                    Label("Support Tromme", systemImage: "heart.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

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
        }
        .padding(24)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showPaywall) { PlusPaywallView() }
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        PlusWelcomeView()
    }
}
