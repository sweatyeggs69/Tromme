import SwiftUI
import StoreKit

/// Tromme Plus subscription sheet, using the system subscription store view.
struct PlusPaywallView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: PlusStore.subscriptionProductIDs) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Tromme Plus")
                    .font(.largeTitle.bold())
                Text("Get access to the premium icons, animated artwork, advanced playback options and support ongoing development of Tromme.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
        }
        .storeButton(.visible, for: .restorePurchases)
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success) = result {
                await PlusStore.shared.refresh()
                dismiss()
            }
        }
    }
}

#Preview {
    PlusPaywallView()
}
