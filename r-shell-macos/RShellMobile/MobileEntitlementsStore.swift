import Foundation
import StoreKit
import SwiftUI

@MainActor
final class MobileEntitlementsStore: ObservableObject {
    static let shared = MobileEntitlementsStore()
    static let freeSavedHostLimit = 3
    static let proLifetimeProductId = "com.r-shell.mobile.pro.lifetime"

    @Published private(set) var isPro = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var status: MobileStoreStatus = .idle
    @Published var lastError: String?

    private var transactionUpdatesTask: Task<Void, Never>?
    private var started = false

    var proLifetimeProduct: Product? {
        products.first { $0.id == Self.proLifetimeProductId }
    }

    var configuredProductIds: [String] {
        [Self.proLifetimeProductId]
    }

    var limitSummary: String {
        isPro ? "Pro active" : "Free: \(Self.freeSavedHostLimit) saved hosts"
    }

    func canCreateConnection(currentCount: Int) -> Bool {
        isPro || currentCount < Self.freeSavedHostLimit
    }

    func start() {
        guard !started else { return }
        started = true
        transactionUpdatesTask = listenForTransactionUpdates()

        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    func loadProducts() async {
        status = .loadingProducts
        defer { status = .idle }

        do {
            products = try await Product.products(for: configuredProductIds)
            if products.isEmpty {
                lastError = "No StoreKit products are configured for this build."
            } else {
                lastError = nil
            }
        } catch {
            lastError = "Could not load StoreKit products: \(error.localizedDescription)"
        }
    }

    func purchaseLifetimeUnlock() async {
        status = .purchasing
        defer { status = .idle }

        if proLifetimeProduct == nil {
            await loadProducts()
        }

        guard let product = proLifetimeProduct else {
            lastError = "The Pro unlock product is not available in this build."
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try MobileStoreKitVerifier.checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements()
                lastError = nil
            case .pending:
                lastError = "Purchase is pending approval."
            case .userCancelled:
                break
            @unknown default:
                lastError = "Purchase did not complete."
            }
        } catch {
            lastError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    func restorePurchases() async {
        status = .restoring
        defer { status = .idle }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            lastError = isPro ? nil : "No Pro purchase was found for this Apple ID."
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        var proUnlocked = false

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? MobileStoreKitVerifier.checkVerified(result) else {
                continue
            }

            if transaction.productID == Self.proLifetimeProductId,
               transaction.revocationDate == nil {
                proUnlocked = true
            }
        }

        isPro = proUnlocked
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                do {
                    let transaction = try MobileStoreKitVerifier.checkVerified(result)
                    await transaction.finish()
                    await self?.refreshEntitlements()
                } catch {
                    await MainActor.run {
                        self?.lastError = "Could not verify the updated StoreKit transaction."
                    }
                }
            }
        }
    }
}

enum MobileStoreStatus: Equatable {
    case idle
    case loadingProducts
    case purchasing
    case restoring

    var isBusy: Bool {
        self != .idle
    }
}

private enum MobileStoreKitVerifier {
    static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified:
            throw MobileStoreKitVerificationError.unverifiedTransaction
        }
    }
}

private enum MobileStoreKitVerificationError: Error {
    case unverifiedTransaction
}

struct MobileProUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore

    let currentSavedHosts: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    featureList
                    purchaseControls
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("midnight-ssh Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await entitlementsStore.loadProducts()
                await entitlementsStore.refreshEntitlements()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                entitlementsStore.isPro ? "Pro is active" : "Upgrade to Pro",
                systemImage: entitlementsStore.isPro ? "checkmark.seal.fill" : "sparkles"
            )
            .font(.title2.weight(.semibold))
            .foregroundStyle(entitlementsStore.isPro ? .green : .primary)

            Text("Free accounts can save \(MobileEntitlementsStore.freeSavedHostLimit) hosts. You currently have \(currentSavedHosts).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            proFeature("Unlimited saved SSH and SFTP profiles", systemImage: "server.rack")
            proFeature("Use the same terminal, SFTP, editor, and dashboard features", systemImage: "terminal")
            proFeature("Restore purchases on iPhone and iPad with your Apple ID", systemImage: "arrow.clockwise.icloud")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var purchaseControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let product = entitlementsStore.proLifetimeProduct {
                Button {
                    Task { await entitlementsStore.purchaseLifetimeUnlock() }
                } label: {
                    Label("Unlock Pro - \(product.displayPrice)", systemImage: "cart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(entitlementsStore.isPro || entitlementsStore.status.isBusy)

                Text(product.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await entitlementsStore.loadProducts() }
                } label: {
                    Label("Load StoreKit Product", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(entitlementsStore.status.isBusy)
            }

            Button {
                Task { await entitlementsStore.restorePurchases() }
            } label: {
                Label("Restore Purchases", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(entitlementsStore.status.isBusy)

            if entitlementsStore.status.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Contacting the App Store")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastError = entitlementsStore.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func proFeature(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .font(.callout)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
        }
    }
}
