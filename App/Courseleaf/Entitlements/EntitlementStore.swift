import Foundation
import Observation

// Entitlement contract for the optional non-consumable local unlock (see
// docs/PRODUCT_SPEC.md section 5). The StoreKit 2 adapter lives in
// StoreKitEntitlementStore.swift; LocalEntitlementStore is for previews and tests.
//
// Gating policy at launch: `PremiumFeature` has no cases, so every core feature
// is free and no feature check can ever fail. If a gated set is decided before
// submission, add cases here, decide them in `FeatureGate.isAvailable`, and
// keep viewing and exporting documents ungated (product spec section 5).

enum ProductIDs {
    /// Non-consumable unlock. The StoreKit test configuration in
    /// Resources/Courseleaf.storekit declares the same identifier.
    static let unlock = "dev.courseleaf.unlock"
    static let all: [String] = [unlock]
}

/// Features that could be gated behind the unlock. Empty at launch on purpose:
/// nothing is gated until a product and a gated set are configured before launch.
enum PremiumFeature: String, CaseIterable, Hashable, Sendable {}

/// Decides whether a feature is usable given the entitlement state.
struct FeatureGate: Sendable {
    var isUnlocked: Bool
    init(isUnlocked: Bool) { self.isUnlocked = isUnlocked }
    func isAvailable(_ feature: PremiumFeature) -> Bool {
        // The switch is exhaustive over an uninhabited enum; once cases exist,
        // each must be decided explicitly here.
        switch feature {}
    }
}

/// A purchasable product as shown in Settings > Purchases. `displayPrice` is
/// StoreKit's localized string; it is never hardcoded.
struct EntitlementProduct: Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var productDescription: String
    var displayPrice: String
}

enum PurchaseOutcome: Hashable, Sendable {
    case purchased
    /// Ask-to-buy or other deferred approval; the transaction arrives later through `updates`.
    case pending
    case cancelled
}

enum EntitlementError: Error, LocalizedError, Equatable {
    case productUnavailable(String)
    case unverified(String)
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .productUnavailable(let id): return "The product \(id) is not available right now."
        case .unverified(let reason): return "The purchase could not be verified: \(reason)"
        case .storeUnavailable(let reason): return "The App Store could not be reached: \(reason)"
        }
    }
}

/// A snapshot of the entitlement state delivered through `updates()`.
struct EntitlementState: Hashable, Sendable {
    var isUnlocked: Bool
    var products: [EntitlementProduct]
    var lastError: String?
}

/// Read-only view of purchases plus purchase/restore actions. Main-actor bound
/// because SwiftUI observes it directly. Implementations are `@Observable`.
@MainActor
protocol EntitlementStore: AnyObject {
    var isUnlocked: Bool { get }
    var products: [EntitlementProduct] { get }
    var lastError: String? { get }
    var isBusy: Bool { get }
    /// Loads product metadata (prices) from the store. Safe to call repeatedly.
    func loadProducts() async
    func purchase(_ productID: String) async throws -> PurchaseOutcome
    func restore() async throws
    /// A stream of state snapshots; the current state is delivered first. Each
    /// call returns an independent stream.
    func updates() -> AsyncStream<EntitlementState>
}

extension EntitlementStore {
    var featureGate: FeatureGate { FeatureGate(isUnlocked: isUnlocked) }
    var unlockProduct: EntitlementProduct? { products.first { $0.id == ProductIDs.unlock } }
}

/// Fan-out helper shared by the stores: keeps every live continuation and
/// yields the latest state to all of them.
@MainActor
final class EntitlementBroadcaster {
    private var continuations: [UUID: AsyncStream<EntitlementState>.Continuation] = [:]

    func stream(initial: EntitlementState) -> AsyncStream<EntitlementState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(initial)
            self.continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in self.continuations[id] = nil }
            }
        }
    }

    func broadcast(_ state: EntitlementState) {
        for continuation in continuations.values { continuation.yield(state) }
    }

    func finishAll() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }
}

/// Keys under which the last verified entitlement state is cached so the app
/// starts with the last known state while offline. The cache is written only
/// after a verified transaction (or a verified absence of one) has been seen;
/// it is never a source of a grant by itself.
enum EntitlementCacheKeys {
    static let isUnlocked = "entitlements.unlock.lastVerifiedState"
    static let verifiedAt = "entitlements.unlock.lastVerifiedAt"
}
