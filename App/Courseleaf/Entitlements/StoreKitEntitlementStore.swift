import Foundation
import Observation
import StoreKit

/// StoreKit 2 adapter for the non-consumable unlock.
///
/// Rules implemented here:
/// - Products come from `Product.products(for:)`; prices are StoreKit's localized strings.
/// - A purchase result is accepted only through `checkVerified`, never from an
///   unverified `VerificationResult`.
/// - `Transaction.updates` is observed for the lifetime of the store, so
///   purchases completed elsewhere (ask-to-buy approvals, another device,
///   refunds/revocations) are applied without a relaunch.
/// - `Transaction.currentEntitlements` is the source of truth on launch and
///   after Restore Purchases (`AppStore.sync()`). A revoked transaction
///   (`revocationDate != nil`) does not count.
/// - `.pending` purchases (ask to buy) grant nothing until the transaction arrives verified.
/// - Offline: the last verified state is cached in `UserDefaults` and used as
///   the initial state while `currentEntitlements` is consulted; the cache is
///   written only after a verified check, so nothing is ever granted without a
///   verified transaction having been seen.
@MainActor
@Observable
final class StoreKitEntitlementStore: EntitlementStore {
    private(set) var isUnlocked: Bool
    private(set) var products: [EntitlementProduct] = []
    private(set) var lastError: String?
    private(set) var isBusy: Bool = false
    /// Date of the last verified entitlement check, for the Purchases screen.
    private(set) var lastVerifiedAt: Date?

    @ObservationIgnored private var storeProducts: [Product] = []
    @ObservationIgnored private var updateListener: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let broadcaster = EntitlementBroadcaster()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Initial state is the cached *verified* state; it is re-checked immediately below.
        self.isUnlocked = defaults.bool(forKey: EntitlementCacheKeys.isUnlocked)
        self.lastVerifiedAt = defaults.object(forKey: EntitlementCacheKeys.verifiedAt) as? Date
        updateListener = listenForTransactionUpdates()
        Task { [weak self] in
            await self?.refreshCurrentEntitlements()
            await self?.loadProducts()
        }
    }

    deinit {
        updateListener?.cancel()
    }

    var state: EntitlementState { EntitlementState(isUnlocked: isUnlocked, products: products, lastError: lastError) }

    // MARK: EntitlementStore

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: ProductIDs.all)
            storeProducts = loaded
            products = loaded.map {
                EntitlementProduct(id: $0.id, displayName: $0.displayName, productDescription: $0.description, displayPrice: $0.displayPrice)
            }
            lastError = nil
        } catch {
            lastError = EntitlementError.storeUnavailable(error.localizedDescription).localizedDescription
        }
        broadcaster.broadcast(state)
    }

    func purchase(_ productID: String) async throws -> PurchaseOutcome {
        if storeProducts.isEmpty { await loadProducts() }
        guard let product = storeProducts.first(where: { $0.id == productID }) else {
            throw EntitlementError.productUnavailable(productID)
        }
        isBusy = true
        defer { isBusy = false }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            lastError = error.localizedDescription
            broadcaster.broadcast(state)
            throw EntitlementError.storeUnavailable(error.localizedDescription)
        }
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            apply(transaction)
            await transaction.finish()
            return .purchased
        case .pending:
            // Ask to buy / deferred approval: nothing is granted now. The verified
            // transaction, if approved, arrives through `Transaction.updates`.
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        isBusy = true
        defer { isBusy = false }
        do {
            try await AppStore.sync()
        } catch {
            lastError = error.localizedDescription
            broadcaster.broadcast(state)
            throw EntitlementError.storeUnavailable(error.localizedDescription)
        }
        await refreshCurrentEntitlements()
    }

    func updates() -> AsyncStream<EntitlementState> { broadcaster.stream(initial: state) }

    // MARK: Verification and state

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw EntitlementError.unverified(error.localizedDescription)
        case .verified(let safe):
            return safe
        }
    }

    /// Recomputes the unlock from the App Store's current entitlements. Every
    /// transaction is verified; a revoked one (refund, family sharing removed)
    /// does not count.
    private func refreshCurrentEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if ProductIDs.all.contains(transaction.productID), transaction.revocationDate == nil {
                unlocked = true
            }
        }
        setVerifiedState(unlocked: unlocked)
    }

    private func apply(_ transaction: Transaction) {
        guard ProductIDs.all.contains(transaction.productID) else { return }
        setVerifiedState(unlocked: transaction.revocationDate == nil)
    }

    private func setVerifiedState(unlocked: Bool) {
        isUnlocked = unlocked
        lastError = nil
        let now = Date()
        lastVerifiedAt = now
        defaults.set(unlocked, forKey: EntitlementCacheKeys.isUnlocked)
        defaults.set(now, forKey: EntitlementCacheKeys.verifiedAt)
        broadcaster.broadcast(state)
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleUpdate(result)
            }
        }
    }

    private func handleUpdate(_ result: VerificationResult<Transaction>) async {
        do {
            let transaction = try checkVerified(result)
            apply(transaction)
            await transaction.finish()
        } catch {
            // An unverified transaction is ignored and never finished, so StoreKit retries it.
            lastError = error.localizedDescription
            broadcaster.broadcast(state)
        }
    }
}
