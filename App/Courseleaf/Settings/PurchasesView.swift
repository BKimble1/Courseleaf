import SwiftUI

/// Purchases: the optional one-time unlock and Restore Purchases. Nothing is
/// gated at launch, and the price string always comes from StoreKit.
struct PurchasesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isWorking = false
    @State private var message: String? = nil

    private var store: any EntitlementStore { env.entitlements }

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: store.isUnlocked ? "Unlocked" : "Not purchased")
                    .accessibilityLabel("Purchase status")
                    .accessibilityValue(store.isUnlocked ? "Unlocked" : "Not purchased")
            } header: {
                Text("This iPad")
            } footer: {
                Text("Every feature in this version is available without a purchase. Nothing you have written is ever locked away.")
            }

            Section("Available") {
                if let product = store.unlockProduct {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.displayName).cardTitleStyle()
                        Text(product.productDescription).detailTextStyle()
                        Text(product.displayPrice).font(Typography.body)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(product.displayName), \(product.displayPrice)")
                    Button {
                        Task { await purchase(product.id) }
                    } label: {
                        Label("Buy \(product.displayPrice)", systemImage: "cart")
                    }
                    .disabled(isWorking || store.isBusy || store.isUnlocked)
                } else {
                    Text("No product is configured for this build, so there is nothing to buy.")
                        .detailTextStyle()
                }
            }

            Section {
                Button {
                    Task { await restore() }
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                }
                .disabled(isWorking || store.isBusy)
            } footer: {
                Text("Restoring asks the App Store for purchases made with your Apple Account, on this or another device.")
            }

            if let error = store.lastError {
                Section("Last problem") {
                    Text(error).foregroundStyle(Palette.danger)
                }
            }
            if let message {
                Section { Text(message).detailTextStyle() }
            }
        }
        .navigationTitle("Purchases")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadProducts() }
    }

    private func purchase(_ productID: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await store.purchase(productID) {
            case .purchased: message = "Thank you. The unlock is active on this iPad."
            case .pending: message = "The purchase needs approval. It will finish on its own once approved."
            case .cancelled: message = "The purchase was cancelled. Nothing was charged."
            }
        } catch {
            env.present(error, title: "The purchase could not be completed")
        }
    }

    private func restore() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.restore()
            message = store.isUnlocked ? "Your purchase was restored." : "No previous purchase was found for this Apple Account."
        } catch {
            env.present(error, title: "Purchases could not be restored")
        }
    }
}
