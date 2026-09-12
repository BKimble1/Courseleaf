import Foundation
import Observation

/// In-memory entitlement store for previews and tests. Purchases succeed or
/// fail according to `purchaseBehaviour`, and every change is broadcast to
/// `updates()` subscribers exactly like the StoreKit store.
@MainActor
@Observable
final class LocalEntitlementStore: EntitlementStore {
    enum PurchaseBehaviour: Hashable, Sendable {
        case succeed, pending, cancel, fail(String)
    }

    private(set) var isUnlocked: Bool
    private(set) var products: [EntitlementProduct]
    private(set) var lastError: String?
    private(set) var isBusy: Bool = false
    var purchaseBehaviour: PurchaseBehaviour = .succeed
    /// Products reported after `loadProducts()`; nil keeps `products` as passed in.
    var loadableProducts: [EntitlementProduct]?
    private(set) var loadProductsCallCount = 0
    private(set) var restoreCallCount = 0
    private let broadcaster = EntitlementBroadcaster()

    init(isUnlocked: Bool = false, products: [EntitlementProduct] = [LocalEntitlementStore.sampleProduct]) {
        self.isUnlocked = isUnlocked
        self.products = products
    }

    static let sampleProduct = EntitlementProduct(
        id: ProductIDs.unlock,
        displayName: "Courseleaf Unlock",
        productDescription: "One-time unlock (nothing is gated at launch).",
        displayPrice: "$4.99")

    var state: EntitlementState { EntitlementState(isUnlocked: isUnlocked, products: products, lastError: lastError) }

    func loadProducts() async {
        loadProductsCallCount += 1
        if let loadableProducts { products = loadableProducts }
        broadcaster.broadcast(state)
    }

    func purchase(_ productID: String) async throws -> PurchaseOutcome {
        guard products.contains(where: { $0.id == productID }) else {
            lastError = EntitlementError.productUnavailable(productID).localizedDescription
            broadcaster.broadcast(state)
            throw EntitlementError.productUnavailable(productID)
        }
        isBusy = true
        defer { isBusy = false }
        switch purchaseBehaviour {
        case .succeed:
            setUnlocked(true)
            return .purchased
        case .pending:
            return .pending
        case .cancel:
            return .cancelled
        case .fail(let reason):
            lastError = reason
            broadcaster.broadcast(state)
            throw EntitlementError.storeUnavailable(reason)
        }
    }

    func restore() async throws {
        restoreCallCount += 1
        broadcaster.broadcast(state)
    }

    func updates() -> AsyncStream<EntitlementState> { broadcaster.stream(initial: state) }

    /// Test hook: simulates a transaction arriving (purchase elsewhere, revocation, refund).
    func setUnlocked(_ unlocked: Bool) {
        isUnlocked = unlocked
        lastError = nil
        broadcaster.broadcast(state)
    }
}
