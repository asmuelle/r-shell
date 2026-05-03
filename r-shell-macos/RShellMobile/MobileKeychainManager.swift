import Foundation
import LocalAuthentication
import Security

enum MobileCredentialKind: String, Sendable {
    case sshPassword = "ssh-password"
    case sshKeyPassphrase = "ssh-key-passphrase"

    var service: String {
        "com.r-shell.mobile.\(rawValue)"
    }

    var displayName: String {
        switch self {
        case .sshPassword:
            return "password"
        case .sshKeyPassphrase:
            return "key passphrase"
        }
    }
}

@MainActor
final class MobileKeychainManager: ObservableObject {
    static let shared = MobileKeychainManager()

    @Published private(set) var vaultUnlocked = false
    @Published private(set) var credentialRevision = 0
    @Published var lastError: String?

    private let unlockTTL: TimeInterval = 5 * 60
    private var unlockedUntil: Date?

    private init() {}

    func hasSecret(kind: MobileCredentialKind, account: String) -> Bool {
        var query = baseQuery(kind: kind, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    @discardableResult
    func saveSecret(kind: MobileCredentialKind, account: String, secret: String) -> Bool {
        guard let data = secret.data(using: .utf8) else {
            lastError = "Credential could not be encoded."
            return false
        }

        let query = baseQuery(kind: kind, account: account)
        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            lastError = nil
            noteCredentialStoreChanged()
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            setLastError("Could not save \(kind.displayName)", status: updateStatus)
            return false
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            setLastError("Could not save \(kind.displayName)", status: status)
            return false
        }

        lastError = nil
        noteCredentialStoreChanged()
        return true
    }

    func loadSecret(
        kind: MobileCredentialKind,
        account: String,
        reason: String
    ) async -> String? {
        guard await unlockVault(reason: reason) else { return nil }

        var query = baseQuery(kind: kind, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            setLastError("Could not read \(kind.displayName)", status: status)
            return nil
        }
        guard
            let data = item as? Data,
            let secret = String(data: data, encoding: .utf8)
        else {
            lastError = "Saved \(kind.displayName) is unreadable."
            return nil
        }

        lastError = nil
        return secret
    }

    @discardableResult
    func deleteSecret(
        kind: MobileCredentialKind,
        account: String,
        reportErrors: Bool = true
    ) -> Bool {
        let status = SecItemDelete(baseQuery(kind: kind, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            if reportErrors {
                setLastError("Could not delete \(kind.displayName)", status: status)
            }
            return false
        }

        if status == errSecSuccess {
            noteCredentialStoreChanged()
        }
        if reportErrors {
            lastError = nil
        }
        return true
    }

    func deleteCredentials(for profile: MobileConnectionProfile) {
        deleteSecret(kind: .sshPassword, account: profile.keychainAccount, reportErrors: false)
        deleteSecret(kind: .sshKeyPassphrase, account: profile.keychainAccount, reportErrors: false)
    }

    func lockVault() {
        vaultUnlocked = false
        unlockedUntil = nil
    }

    func unlockVault(reason: String) async -> Bool {
        if let unlockedUntil, unlockedUntil > Date() {
            return true
        }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            vaultUnlocked = true
            unlockedUntil = Date().addingTimeInterval(60)
            return true
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            vaultUnlocked = success
            unlockedUntil = success ? Date().addingTimeInterval(unlockTTL) : nil
            return success
        } catch {
            vaultUnlocked = false
            unlockedUntil = nil
            lastError = error.localizedDescription
            return false
        }
    }

    private func baseQuery(kind: MobileCredentialKind, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.service,
            kSecAttrAccount as String: account
        ]
    }

    private func noteCredentialStoreChanged() {
        credentialRevision += 1
    }

    private func setLastError(_ prefix: String, status: OSStatus) {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            lastError = "\(prefix): \(message)"
        } else {
            lastError = "\(prefix): OSStatus \(status)"
        }
    }
}
