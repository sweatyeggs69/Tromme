import StoreKit

/// Tromme Plus entitlement: premium app icons and animated artwork.
/// Change product IDs here (and in App Store Connect / Configuration.storekit).
@Observable
@MainActor
final class PlusStore {
    static let shared = PlusStore()

    /// Auto-renewable subscription products, in the order the paywall lists them.
    nonisolated static let subscriptionProductIDs = ["TPLUS", "TPLUSYEAR"]
    /// Old one-time Premium Icon Pack purchase. Owners are grandfathered into Plus.
    nonisolated static let legacyProductIDs = ["PremiumIP"]

    private nonisolated static let cacheKey = "plusUnlocked"

    /// Last known entitlement, readable from any context (e.g. before StoreKit answers at launch).
    nonisolated static var cachedIsPlus: Bool {
        UserDefaults.standard.bool(forKey: cacheKey)
    }

    private(set) var isPlus = PlusStore.cachedIsPlus
    /// True once entitlements have been read this launch.
    private(set) var hasLoaded = false
    /// Plus comes only from an old Premium Icon Pack purchase, not a subscription.
    private(set) var isGrandfathered = false

    private var started = false

    private init() {}

    /// Begin observing entitlements. Safe to call more than once.
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
        isGrandfathered = legacy && !subscribed
        hasLoaded = true
        setPlus(entitled)
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
