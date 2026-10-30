import SwiftUI
import StoreKit

struct PlusPaywallView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: PlusStore.subscriptionProductIDs) {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                    Text("Tromme +")
                        .font(.largeTitle.bold())
                }
                PlusFeaturesView()
            }
            .padding(.horizontal, 24)
        }
        .subscriptionStoreControlStyle(.prominentPicker)
        .storeButton(.visible, for: .restorePurchases)
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(let verification)) = result {
                await PlusStore.shared.completePurchase(verification)
                dismiss()
            }
        }
    }
}

#Preview {
    PlusPaywallView()
}
