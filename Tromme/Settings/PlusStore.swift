import StoreKit

@Observable
@MainActor
final class PlusStore {
    static let shared = PlusStore()

    nonisolated static let subscriptionProductIDs = ["TPLUS", "TPLUSYEAR"]
    nonisolated static let legacyProductIDs = ["PremiumIP"]

    private nonisolated static let cacheKey = "plusUnlocked"

    nonisolated static var cachedIsPlus: Bool {
        UserDefaults.standard.bool(forKey: cacheKey)
    }

    private(set) var isPlus = PlusStore.cachedIsPlus
    private(set) var hasLoaded = false
    private(set) var isGrandfathered = false

    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
        Task { await listenForUpdates() }
    }

    func refresh() async {
        var entitled = false
        var subscribed = false
        var legacy = false
        let ids = Set(Self.subscriptionProductIDs + Self.legacyProductIDs)
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ids.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            entitled = true
            if Self.legacyProductIDs.contains(transaction.productID) { legacy = true } else { subscribed = true }
        }
        if !entitled {
            for id in ids {
                guard case .verified(let transaction)? = await Transaction.latest(for: id),
                      transaction.revocationDate == nil,
                      transaction.expirationDate.map({ $0 > .now }) ?? true else { continue }
                entitled = true
                if Self.legacyProductIDs.contains(id) { legacy = true } else { subscribed = true }
            }
        }
        isGrandfathered = legacy && !subscribed
        hasLoaded = true
        setPlus(entitled)
    }

    func completePurchase(_ result: VerificationResult<Transaction>) async {
        if case .verified(let transaction) = result {
            await transaction.finish()
        }
        await refresh()
    }

    private func setPlus(_ value: Bool) {
        isPlus = value
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
    }

    private func listenForUpdates() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
            }
            await refresh()
        }
    }
}
