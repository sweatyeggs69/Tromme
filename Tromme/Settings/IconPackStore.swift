import StoreKit

@Observable
@MainActor
final class IconPackStore {
    let productID: String

    private(set) var product: Product?
    private(set) var isPurchased = false
    private(set) var isPurchasing = false
    private(set) var isLoadingProduct = true
    var purchaseError: String?

    init(productID: String) {
        self.productID = productID
        Task { await load() }
        Task { await listenForUpdates() }
    }

    func load() async {
        isLoadingProduct = true
        do {
            let products = try await Product.products(for: [productID])
            product = products.first
        } catch {
            #if DEBUG
            print("[IconPackStore] Failed to load product: \(error)")
            #endif
        }
        isLoadingProduct = false
        await refreshPurchaseStatus()
    }

    func refreshPurchaseStatus() async {
        var purchased = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == productID { purchased = true }
        }
        isPurchased = purchased
    }

    func purchase() async {
        if product == nil { await load() }
        guard let product else {
            purchaseError = "Couldn't load the product. Check your connection and try again."
            return
        }
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { break }
                await transaction.finish()
                isPurchased = true
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restore() async {
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refreshPurchaseStatus()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    private func listenForUpdates() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result,
                  transaction.productID == productID else { continue }
            await transaction.finish()
            isPurchased = true
        }
    }
}
